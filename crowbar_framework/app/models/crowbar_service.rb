#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class CrowbarService < ServiceObject
  attr_accessor :transition_save_node

  def initialize(thelogger = nil)
    super
    @bc_name = "crowbar"
  end

  class << self
    def role_constraints
      {
        "crowbar" => {
          "count" => 1,
          "admin" => true,
          "exclude_platform" => {
            "windows" => "/.*/"
          }
        }
      }
    end
  end

  def create_proposal
    base = super
    base["attributes"]["crowbar"]["client_user"]["password"] = random_password
    base
  end

  # This is relevant to upgrade process only.
  #
  # Commit current proposal of crowbar barclamp and check if the commit doesn't
  # end with some errors.
  #
  # Unfortunatelly we need to explicitely look at crowbar-status of the proposal
  # because apply_role from this model ignores errors from superclass's apply_role.
  def commit_and_check_proposal
    answer = proposal_commit(
      "default",
      in_queue: false,
      validate: false,
      validate_after_save: false
    )
    # check if error message is saved in one of the nodes
    if answer.first != 200
      found_errors = []
      Node.find("state:crowbar_upgrade").each do |node|
        error = node["crowbar_wall"]["chef_error"] || ""
        next if error.empty?
        found_errors.push error
        Rails.logger.error("Chef run ended with an error on the node #{node.name}: #{error}")
        node["crowbar_wall"]["chef_error"] = ""
        node.save
      end
      unless found_errors.empty?
        raise found_errors.join("\n")
      end
    end

    proposal = Proposal.where(barclamp: "crowbar", name: "default").first
    # there could be different error than one raised from a recipe
    if proposal["deployment"]["crowbar"]["crowbar-status"] == "failed"
      raise proposal["deployment"]["crowbar"]["crowbar-failed"]
    end
  end

  # Ensure the nodes are reachable before trying to apply the proposals
  def check_if_nodes_are_available(upgrade_nodes)
    unavailable_nodes = []
    upgrade_nodes.each do |node|
      ssh_status = node.ssh_cmd("")
      if ssh_status[0] != 200
        unavailable_nodes.push node.name
      end
    end
    unless unavailable_nodes.empty?
      raise I18n.t("model.service.nodes_not_available", names: unavailable_nodes.join(", "))
    end
  end

  #
  # Below are the parts to handle transition requests.
  #
  # This routine handles name-based state transitions.  The system will then inform barclamps.
  # It will create a node and assign it an admin address.
  #
  def transition(inst, name, state)
    self.transition_save_node = false

    return [404, "No state specified"] if state.nil?
    # FIXME: validate state

    Rails.logger.info("Crowbar transition enter: #{name} to #{state}")

    pop_it = false
    node = nil

    with_lock "BA-LOCK" do
      node = Node.find_by_name(name)
      if node.nil? and (state == "discovering" or state == "testing")
        Rails.logger.debug("Crowbar transition: creating new node for #{name} to #{state}")
        node = Node.create_new name
        self.transition_save_node = true
      end
      if node.nil?
        Rails.logger.error(
          "Crowbar transition leaving: node not found nor created - #{name} to #{state}"
        )
        return [404, "Node not found"]
      end

      if %w(hardware-installing hardware-updating update).include? state
        Rails.logger.debug("Crowbar transition: force run because of state #{name} to #{state}")
        pop_it = true
      end

      if node.crowbar["state"] != state
        Rails.logger.debug(
          "Crowbar transition: state has changed so we need to do stuff for #{name} to #{state}"
        )

        # Do not allow change to shutdown state from crowbar_upgrade
        # (we need to reboot the nodes for upgrade, but without changing the state)
        if node.crowbar["state"] == "crowbar_upgrade" && state == "shutdown"
          Rails.logger.debug("current node state is crowbar_upgrade; ignoring change to shutdown")
          return [200, { name: name }]
        end

        node.crowbar["crowbar"]["state_debug"] = {} if node.crowbar["crowbar"]["state_debug"].nil?
        if node.crowbar["crowbar"]["state_debug"][state].nil?
          node.crowbar["crowbar"]["state_debug"][state] = 1
        else
          node.crowbar["crowbar"]["state_debug"][state] = node.crowbar["crowbar"]["state_debug"][state] + 1
        end

        node.crowbar["state"] = state
        node.crowbar["state_change_time"] = Time.new.to_s
        self.transition_save_node = true
        pop_it = true
      end

      node.save if transition_save_node
    end

    if pop_it
      #
      # If we are discovering the node and it is an admin,
      # make sure that we add the crowbar config
      #
      if state == "discovering" and node.admin?
        crole = RoleObject.find_role_by_name("crowbar-config-#{inst}")
        db = Proposal.where(barclamp: "crowbar", name: inst).first
        add_role_to_instance_and_node("crowbar", inst, name, db, crole, "crowbar")
      end

      roles = RoleObject.find_roles_by_search "transitions:true AND (transition_list:all OR transition_list:#{ChefObject.chef_escape(state)})"
      # Sort rules for transition order (deployer should be near the beginning if not first).
      roles.sort! do |x,y|
        xname = x.name.gsub(/-config-.*$/, "")
        yname = y.name.gsub(/-config-.*$/, "")

        xs = BarclampCatalog.run_order(xname)
        ys = BarclampCatalog.run_order(yname)
        xs <=> ys
      end

      roles.each do |role|
        role.override_attributes.each do |bc, data|
          rname = role.name.gsub("#{bc}-config-","")
          # Need a lock here, because if many nodes are discovered
          # simultaneously, adding them to a proposal can race,
          # leaving some nodes not present in proposals. e.g.:
          # NtpService::transition uses find_proposal and
          # later saves it with add_role_to_instance_and_node().
          # If this runs for two nodes at the same time, they both
          # find the proposal, then both modify it, then both save
          # it in lockstep.  Naturally the second save clobbers
          # the first, so the first node won't be present in that
          # proposal.
          bc_lock = acquire_lock "#{bc}:#{rname}"
          begin
            Rails.logger.info("Crowbar transition: calling #{bc}:#{rname} for #{name} for #{state}")
            service = ServiceObject.get_service(bc).new
            answer = service.transition(rname, name, state)
            if answer[0] != 200
              Rails.logger.error(
                "Crowbar transition: finished #{bc}:#{rname} for #{name} for " \
                "#{state}: FAILED #{answer[1]}"
              )
            else
              Rails.logger.debug(
                "Crowbar transition: finished #{bc}:#{rname} for #{name} for #{state}"
              )
              unless answer[1]["name"].nil?
                name = answer[1]["name"]
              end
            end
          rescue StandardError => e
            Rails.logger.fatal("json/transition for #{bc}:#{rname} failed: #{e.message}")
            Rails.logger.fatal(e.backtrace.join("\n"))
            return [500, "#{bc} transition to #{rname} failed.\n#{e.message}\n#{e.backtrace.join("\n")}"]
          ensure
            bc_lock.release
          end
        end
      end

      # We have a node that has become ready, test to see if there are queued proposals to commit
      process_queue if state == "ready"
    end

    Rails.logger.debug("Crowbar transition leaving: #{name} to #{state}")
    [200, { name: name }]
  end

  def prepare_nodes_for_crowbar_upgrade
    proposal = Proposal.find_by(barclamp: "crowbar", name: "default")

    # To all nodes, add a new role which prepares them for the upgrade
    nodes_to_upgrade = []
    not_ready_for_upgrade = []
    admin_with_dns_server_role = false
    all_nodes = Node.all
    all_nodes.each do |n|
      not_ready_for_upgrade.push n.name if !n.admin? && !%w(ready crowbar_upgrade).include?(n.state)
      admin_with_dns_server_role = true if n.admin? && n.role?("dns-server")
    end

    unless admin_with_dns_server_role
      raise I18n.t("installer.upgrades.prepare.admin_missing_dns_server")
    end

    unless not_ready_for_upgrade.empty?
      raise I18n.t(
        "installer.upgrades.prepare.nodes_not_ready", nodes: not_ready_for_upgrade.join(", ")
      )
    end

    all_nodes.each do |node|
      next if node.admin?

      if node[:platform] == "windows"
        # for Hyper-V nodes, only change the state, but do not run chef-client
        node.set_state("crowbar_upgrade")
      else
        node.crowbar["crowbar_upgrade_step"] = "crowbar_upgrade"
        node.save
        nodes_to_upgrade.push node.name
      end
    end

    # adapt current proposal, so the nodes get crowbar-upgrade role
    proposal.raw_data["deployment"]["crowbar"]["elements"]["crowbar-upgrade"] = nodes_to_upgrade
    proposal.save
    # commit the proposal so chef recipe get executed
    proposal_commit("default", in_queue: false, validate_after_save: false)
  end

  def disable_non_core_proposals
    upgrade_nodes = Node.all.reject(&:admin?)
    check_if_nodes_are_available upgrade_nodes

    # Find all non-core proposals and remove all roles that belong
    # to those proposals from the nodes
    active_non_core_roles = RoleObject.find_roles_by_name("*-config-*").reject(&:core_role?)

    # Add crowbar-upgrade role and crowbar-config-default roles to handle
    # crowbar-upgrade removal from nodes
    upgrade_role = RoleObject.find_role_by_name("crowbar-upgrade")
    crowbar_config_role = RoleObject.find_role_by_name("crowbar-config-default")

    roles_to_disable = active_non_core_roles
    roles_to_disable << upgrade_role unless upgrade_role.nil?
    roles_to_disable << crowbar_config_role

    upgrade_nodes.each do |node|
      roles_to_disable.each do |role|
        roles_to_remove = role.elements.keys
        roles_to_remove << role.name
        roles_to_remove.each do |delete_role|
          node.delete_from_run_list(delete_role)
        end
      end
      node.save
    end

    # finally delete the roles itself
    active_non_core_roles.each(&:destroy)
    crowbar_config_role.elements["crowbar-upgrade"] = []
    crowbar_config_role.save
  end

  # After the admin serve has been upgraded, and once it has repositories
  # correctly prepared for nodes, prepare the upgrade script at the nodes
  def prepare_nodes_for_os_upgrade
    upgrade_nodes = Node.all.reject do |node|
      node.admin? || node[:platform] == "windows" || node.state != "crowbar_upgrade"
    end
    check_if_nodes_are_available upgrade_nodes
    admin_node = Node.admin_node

    upgrade_nodes.each do |node|
      node["target_platform"] = admin_node["provisioner"]["default_os"]
      node.crowbar["crowbar_upgrade_step"] = "prepare-os-upgrade"
      # skip initial keystone bootstrapping
      if node["run_list_map"].key? "keystone-server"
        node["keystone"]["bootstrap"] = true
      end
      node.save
    end

    # unset `db_synced` flag for OpenStack components
    ::Openstack::Upgrade.unset_db_synced

    commit_and_check_proposal
  end

  # Prepare the upgrade AutoYaST profile for nodes and let them use it for the upgrade
  # This is the method from 5-6 upgrade. To be removed once we have full replacement
  def initiate_nodes_upgrade
    upgrade_nodes = Node.all.reject do |node|
      node.admin? || node[:platform] == "windows" || node.state != "crowbar_upgrade"
    end
    check_if_nodes_are_available upgrade_nodes
    admin_node = Node.admin_node
    upgrade_nodes_failed = []

    upgrade_nodes.each do |node|
      node["target_platform"] = admin_node["provisioner"]["default_os"]
      node.save
      node.set_state("os-upgrading")
    end

    # wait for the pxe_config to be updated, then reboot the nodes
    discovery_dir = "#{Node.admin_node[:provisioner][:root]}/discovery/"
    pxecfg_subdir = "bios/pxelinux.cfg"

    upgrade_nodes.each do |node|
      boot_ip_hex = node["crowbar"]["boot_ip_hex"]
      node_arch = node["kernel"]["machine"]
      pxe_conf = "#{discovery_dir}/#{node_arch}/#{pxecfg_subdir}/#{boot_ip_hex}"
      ready_for_reboot = false

      while Time.now.to_i < Time.now.to_i + 120 && !ready_for_reboot
        Rails.logger.debug("waiting for pxe configuration to be updated for #{node.name}")
        if File.file?(pxe_conf)
          File.open(pxe_conf).each_line do |line|
            line.chomp!
            if line =~ /^DEFAULT\s+.+_install$/
              ready_for_reboot = true
            end
          end.close
        end
        sleep(5) unless ready_for_reboot
      end
      if ready_for_reboot
        Rails.logger.debug("Rebooting node #{node.name} for operating system upgrade")
        ssh_status = node.ssh_cmd("/sbin/reboot")
        if ssh_status[0] != 200
          Rails.logger.error("Upgrade failed for machine #{node.name}. Could not ssh.")
          upgrade_nodes_failed.push(node.name)
        end
      else
        Rails.logger.error("Upgrade failed for #{node.name}. Node not ready for reboot")
        upgrade_nodes_failed.push(node.name)
      end
    end
    # If list is empty, this method was successful.
    upgrade_nodes_failed
  end

  def revert_nodes_from_crowbar_upgrade
    proposal = Proposal.find_by(barclamp: "crowbar", name: "default")

    Node.all.each do |node|
      next unless node.state == "crowbar_upgrade"
      # revert nodes to previous state; set "crowbar_upgrade_step" so apply does not
      # change state again
      node.crowbar["crowbar_upgrade_step"] = "revert_to_ready"
      node.save
      node.set_state("ready")
    end

    # commit current proposal (with the crowbar-upgrade role still assigned to nodes),
    # so the recipe is executed when nodes have 'ready' state
    proposal_commit("default", in_queue: false, validate: false, validate_after_save: false)
    # now remove the nodes from upgrade role
    proposal["deployment"]["crowbar"]["elements"]["crowbar-upgrade"] = []
    proposal.save
  end

  def apply_role_pre_chef_call(old_role, role, all_nodes)
    Rails.logger.debug("crowbar apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    all_nodes.each do |n|
      node = Node.find_by_name(n)
      # value of node.crowbar["crowbar_upgrade_step"] indicates that the role should be executed
      # but node state should not be changed: this is needed when reverting node state to ready
      if node.role?("crowbar-upgrade") &&
          node.crowbar["crowbar_upgrade_step"] != "revert_to_ready"
        node.set_state("crowbar_upgrade")
      end
    end

    # save sync_mark attributes in config databag for the sync_mark provider to fetch
    item = Crowbar::DataBagConfig.get_or_create_databag_item("crowbar-config", "sync_mark")
    item.update(role.default_attributes["crowbar"]["sync_mark"])
    item.save
  end

  def apply_role(role, inst, in_queue, bootstrap = false)
    Rails.logger.debug("Crowbar apply_role: enter")
    answer = super
    if answer.first != 200
      Rails.logger.error("Crowbar apply_role: super apply_role finished with error")
      return answer
    end
    Rails.logger.debug("Crowbar apply_role: super apply_role finished")

    answer = bootstrap_proposals(role, inst)

    if answer[0] != 200
      Rails.logger.error("Crowbar apply_role: #{answer.inspect}")
    else
      Rails.logger.debug("Crowbar apply_role: leaving: #{answer.inspect}")
    end
    answer
  end

  # look at the instances we'll create, and sort them using catalog info
  def order_instances(bcs)
    tmp = {}
    bcs.each { |bc_name,instances|
      order = BarclampCatalog.run_order(bc_name)
      tmp[bc_name] = {order: order, instances: instances}
    }
    #sort by the order value (x,y are an array with the value of
    #the hash entry
    t = tmp.sort{ |x,y| x[1][:order] <=> y[1][:order] }
    Rails.logger.debug("ordered instances: #{t.inspect}")
    t
  end

  def bootstrap_ensure_proposal(bc, override_attr_path)
    Rails.logger.info("Bootstrap: ensure proposal for bc: #{bc}, name: #{override_attr_path}")

    unless override_attr_path == "default" || File.exist?(override_attr_path)
      msg = "Cannot ensure proposal for #{bc} exists: #{override_attr_path} does not exist."
      Rails.logger.error(msg)
      return [404, msg]
    end

    service = ServiceObject.get_service(bc).new
    answer = service.proposals

    if answer[0] != 200
      Rails.logger.error("Failed to list proposals for #{bc}: #{answer[0]}: #{answer[1]}")
      return answer
    end
    proposals = answer[1]

    if override_attr_path != "default"
      # Fetch overriding attributes for new proposal
      data = JSON.parse(
        File.read(override_attr_path)
      )

      id = data["id"].gsub("#{bc}-", "")
    else
      id = "default"
      data = { "id" => id }
    end

    unless proposals.include?(id)
      Rails.logger.debug("Bootstrap: creating proposal for #{bc}.#{id}")
      # on bootstrap, we'll generally want to add the admin server to some
      # roles, so prefill what we know will be needed
      if data["deployment"].nil? ||
          data["deployment"][bc].nil? ||
          data["deployment"][bc]["elements"].nil?
        data["crowbar-deep-merge-template"] = true
      end
      data["deployment"] ||= {}
      data["deployment"][bc] ||= {}
      data["deployment"][bc]["elements"] ||= {}

      answer = service.proposal_create_bootstrap(data)
      if answer[0] != 200
        msg = "Failed to create proposal '#{id}' for barclamp '#{bc}' " \
            "(The error message was: #{answer[1].strip})"
        Rails.logger.error(msg)
        answer[1] = msg
        return answer
      end
    end

    answer = service.list_active
    if answer[0] != 200
      msg = "Failed to list active '#{bc}' proposals " \
          "(The error message was: #{answer[1].strip})"
      Rails.logger.error(msg)
      answer[1] = msg
      return answer
    end
    active_proposals = answer[1]

    unless active_proposals.include?(id)
      Rails.logger.debug("Bootstrap: applying proposal for #{bc}.#{id}")
      answer = service.proposal_commit(
        id,
        in_queue: false,
        validate_after_save: false,
        bootstrap: true
      )
      if answer[0] != 200
        msg = "Failed to commit proposal '#{id}' for '#{bc}' " \
            "(The error message was: #{answer[1].strip})"
        Rails.logger.error(msg)
        answer[1] = msg
        return answer
      end
    end

    Rails.logger.info(
      "Bootstrap: done ensuring proposal for bc: #{bc}, name: #{override_attr_path}"
    )

    answer
  end

  def bootstrap_proposals(crowbar_role, inst)
    answer = [200, {}]

    role = crowbar_role.default_attributes
    return answer if role["crowbar"].nil? ||
        role["crowbar"]["instances"].nil? ||
        role["crowbar"]["instances"].empty?

    Rails.logger.info("Bootstrap: create initial proposals")

    ordered_bcs = order_instances role["crowbar"]["instances"]
    ordered_bcs.each do |bc, plist|
      plist[:instances].each do |v|
        answer = bootstrap_ensure_proposal(bc, v)
        break if answer[0] != 200
      end
      break if answer[0] != 200
    end

    if answer[0] == 200
      Rails.logger.info("Bootstrap successful!")

      # removing bootstrap info to not do this anymore
      proposal = Proposal.where(barclamp: @bc_name, name: inst).first
      proposal.raw_data["attributes"]["crowbar"]["instances"] = {}
      proposal.save

      crowbar_role.default_attributes["crowbar"]["instances"] = {}
      crowbar_role.save
    end

    answer
  end
end
