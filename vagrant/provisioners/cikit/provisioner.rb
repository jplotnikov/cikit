module VagrantPlugins::CIKit
  class Provisioner < Vagrant.plugin("2", :provisioner)
    def provision
      result = Vagrant::Util::Subprocess.execute(
        "bash",
        "-c",
        "#{config.controller} #{config.playbook} #{cikit_args}",
        :workdir => @machine.env.root_path.to_s,
        :notify => [:stdout, :stderr],
        :env => environment_variables,
      ) do |io_name, data|
        @machine.env.ui.info(data, {
          :new_line => false,
          :prefix => false,
        })
      end

      if !result.exit_code.zero?
        raise Vagrant::Errors::VagrantError.new(), "CIKit provisioner responded with a non-zero exit status."
      end
    end

    protected

    def environment_variables
      environment_variables = {}
      environment_variables["ANSIBLE_INVENTORY"] = ansible_inventory
      environment_variables["ANSIBLE_SSH_ARGS"] = ansible_ssh_args
      environment_variables["DEBIAN_FRONTEND"] = "noninteractive"
      environment_variables["CIKIT_LIST_TAGS"] = ENV["CIKIT_LIST_TAGS"]
      environment_variables["CIKIT_VERBOSE"] = ENV["CIKIT_VERBOSE"]
      environment_variables["CIKIT_TAGS"] = ENV["CIKIT_TAGS"]
      environment_variables["PATH"] = ENV["VAGRANT_OLD_ENV_PATH"]

      return environment_variables
    end

    def ansible_ssh_args
      ansible_ssh_args = []
      ansible_ssh_args << "-o ForwardAgent=yes" if @machine.ssh_info[:forward_agent]
      ansible_ssh_args << "-o StrictHostKeyChecking=no"
      ansible_ssh_args << ENV["ANSIBLE_SSH_ARGS"]

      return ansible_ssh_args.join(" ")
    end

    def cikit_args
      args = []
      # Append the host being provisioned.
      args << "--limit=#{@machine.name}"

      playbook = config.playbook ? config.playbook.chomp(File.extname(config.playbook)) + ".yml" : ""

      if File.exist?(playbook)
        taglist = []
        extra_vars = {}
        prompts_file = "#{File.dirname(@machine.env.local_data_path)}/.cikit/environment.yml"
        playbook = YAML::load_file(playbook)
        prompts = File.exists?(prompts_file) ? YAML::load_file(prompts_file) : {}
        taglist = ENV.has_key?("CIKIT_TAGS") ? ENV["CIKIT_TAGS"].split(",") : {}

        parse_env_vars("EXTRA_VARS").each do |var, value|
          if !value.nil?
            extra_vars[var.tr("-", "_")] = value
          end
        end

        if playbook[0].include?("vars_prompt")
          for var_prompt in playbook[0]["vars_prompt"];
            default_value = ""

            # We have previously saved value. Use it as default!
            if prompts.has_key?(var_prompt["name"])
              default_value = prompts[var_prompt["name"]]
            elsif var_prompt.has_key?("default")
              default_value = var_prompt["default"].to_s
            end

            # Use default value if condition intended for not Vagrant or script
            # was run with tags and current prompt have one of them.
            if (taglist.any? && (var_prompt["tags"] & taglist).none?) || "not vagrant" == var_prompt["when"]
              value = default_value
            else
              puts var_prompt["prompt"] + (default_value.empty? ? "" : " [#{default_value}]") + ":"

              # Preselected value in environment variable.
              if extra_vars.has_key?(var_prompt["name"])
                value = extra_vars[var_prompt["name"]]
                # Show preselected value to the user.
                puts value
              else
                value = $stdin.gets.chomp
                value = value.empty? ? default_value : value
              end
            end

            args << "--#{var_prompt["name"]}=#{value}"
            prompts[var_prompt["name"]] = value
          end
        end

        write_cache(prompts_file, YAML::dump(prompts))
      end

      return args.join(" ")
    end

    # Auto-generate "safe" inventory file based on Vagrantfile.
    def ansible_inventory
      inventory_content = ["# Generated by CIKit"]
      inventory_file = "#{@machine.env.local_data_path.to_s}/provisioners/cikit/ansible/inventory"

      # By default, in Cygwin, user's home directory is "/home/<USERNAME>" and it is not the same
      # that "C:\Users\<USERNAME>". All used software (Ansible (~/.ansible), Vagrant (~/.vagrant.d),
      # Virtualbox (~/.VirtualBox), SSH (~/.ssh)) uses correct for Windows path and this breaks a
      # lot of Linux commands (chmod - one of them and we need to use to set correct permissions to
      # SSH private key).
      if Vagrant::Util::Platform.cygwin?
        ENV["HOME"] = Vagrant::Util::Subprocess.execute("cygpath", "-wH").stdout.chomp.gsub("\\", "/") + "/" + Etc.getlogin()
      end

      @machine.env.active_machines.each do |active_machine|
        begin
          m = @machine.env.machine(*active_machine)

          if !m.ssh_info.nil?
            inventory_item = []
            inventory_item << "#{m.name} ansible_host=#{m.ssh_info[:host]}"
            inventory_item << "ansible_port=#{m.ssh_info[:port]}"
            inventory_item << "ansible_user=#{m.ssh_info[:username]}"

            if m.ssh_info[:private_key_path].any?
              inventory_item << "ansible_ssh_private_key_file=#{m.ssh_info[:private_key_path][0].gsub(ENV["HOME"], "~")}"
            else
              inventory_item << "ansible_password=#{m.ssh_info[:password]}"
            end

            inventory_content << inventory_item.join(" ")
          else
            @logger.error("Auto-generated inventory: Impossible to get SSH information for machine '#{m.name} (#{m.provider_name})'. This machine should be recreated.")
            # Let a note about this missing machine
            inventory_content << "# MISSING: '#{m.name}' machine was probably removed without using Vagrant. This machine should be recreated."
          end
        rescue Vagrant::Errors::MachineNotFound => e
          @logger.info("Auto-generated inventory: Skip machine '#{active_machine[0]} (#{active_machine[1]})', which is not configured for this Vagrant environment.")
        end
      end

      write_cache(inventory_file, inventory_content.join("\n"))

      return inventory_file
    end

    # @param env_var [String]
    #   Name of environment variable to parse. Format: "--param1=option --param2=value2".
    #
    # @return [Hash]
    #   List of parsed options and assigned values.
    def parse_env_vars(env_var)
      vars = {}

      ENV.has_key?(env_var) && ENV[env_var].scan(/--?([^=\s]+)(?:=(\S+))?/).each do |pair|
        key, value = pair

        # Trim quotes if string starts and ends by the same character.
        if !value.nil? && ((value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'")))
          value = value[1...-1]
        end

        vars[key] = value
      end

      return vars
    end

    # @param file [String]
    #   Absolute path to file to write to.
    # @param content [String]
    #   Content to store inside the file.
    def write_cache(file, content)
      file = Pathname.new(file)

      if !File.exists?(file)
        dir = File.dirname(file)

        FileUtils.mkdir_p(dir) unless File.directory?(dir)
      end

      Mutex.new.synchronize do
        file.open("w") do |descriptor|
          descriptor.write(content)
        end
      end
    end
  end
end
