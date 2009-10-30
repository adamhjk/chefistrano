require 'capistrano'
require 'chef'
require 'chef/recipe'
require 'chef/node'
require 'chef/role'
require 'chef/search/query'
require 'chef/log'
require 'chef/data_bag'
require 'chef/data_bag_item'
require 'json'

module Chefistrano

  API_OPSCODE_USER = ENV['OPSCODE_USER']
  API_OPSCODE_KEY = ENV['OPSCODE_KEY']

  def rest
    @chefistrano_rest ||= Chef::REST.new(Chef::Config[:chef_server_url], ENV["OPSCODE_USER"], ENV["OPSCODE_KEY"])
  end

  def cap
    Capistrano::Configuration.instance
  end
  
  def gen_temp_file_name
    # Taken from Nanite::Identity.generate
    values = [
      rand(0x0010000),
      rand(0x0010000),
      rand(0x0010000),
      rand(0x0010000),
      rand(0x0010000),
      rand(0x1000000),
      rand(0x1000000),
    ]
    random = "%04x%04x%04x%04x%04x%06x%06x" % values
    "chefistrano-#{random}"
  end

  def get_ohai
    od = Hash.new
    run("ohai") do |ch, stream, data| 
      raise "error: #{data}" if stream == :err
      od[ch[:host]] = data
    end
    od
  end

  def recipe(&block)
    od = get_ohai
    nodes = Hash.new
    recipes = Hash.new

    od.each do |host, data|
      nodes[host] = data
    end

    r = Chef::Recipe.new("cap", "cap", Chef::Node.new)
    r.instance_eval(&block)
    put({ :chefistrano => r.collection }.to_json, gen_temp_file_name, { :mode => 0644 })
  end

  def setup
    search(:node, '*:* AND NOT status:down') do |node|
      server_fqdn = node.fqdn
      if node.attribute?("ec2")
        server_fqdn = node.ec2.public_hostname
      end
      roles = node.run_list.roles
      roles << "all_chef"
      recipes, default_attributes, override_attributes = node.run_list.expand
      node.default = default_attributes
      node.override = override_attributes
      roles << { 
        :app_environment => node.attribute?(:app_environment) ? node.app_environment : "none" 
      }
      Capistrano::Configuration.instance.server server_fqdn, *roles
    end
  end

  def search(index, query="*:*", sort=nil, start=0, rows=20, &block)
    q = Chef::Search::Query.new
    q.rest = rest
    if block
      q.search(index, query, sort, start, rows, &block)
    else
      q.search(index, query, sort, start, rows)
    end
  end

  def run_chef_client
    log_level = ENV["LOG_LEVEL"] ? ENV["LOG_LEVEL"] : "error"
    cmd = "#{sudo} chef-client -l #{log_level}"
    tempfile = nil
    if ENV['JSON']
      tempfile = "/tmp/#{chefistrano.gen_temp_file_name}" 
      upload(ENV['JSON'], tempfile) 
      cmd << " -j #{ENV['JSON']}" 
    end
    run(cmd)
    run("#{sudo} rm #{tempfile}") if ENV['JSON']
  end

end

Chef::Config.from_file("/etc/chef/client.rb")
Chef::Config[:node_name] = ENV['OPSCODE_USER']
Chef::Config[:client_key] = ENV['OPSCODE_KEY']
Chef::Log::Formatter.show_time = false
Chef::Log.level(:error)
Mixlib::Authentication::Log.level(:error)
Capistrano.plugin :chefistrano, Chefistrano 
Capistrano::Configuration.instance.chefistrano.setup

Capistrano::Configuration.instance.namespace(:chef) do
  desc <<-DESC
    Run the chef-client on the remote servers.  Use the ROLES environment \
    variable as a comma-delimited list of role names to run the command on, \
    or use the HOSTS environment variable.  

    You can also use the JSON argument to point to a local file, which will \
    be transferred and passed to the -j option to chef-client.

    Sample usage:

      $ cap chef:client ROLES=webserver
      $ cap chef:client ROLES=webserver,database
      $ cap chef:client HOSTS=foo.bar.com 
      $ cap chef:client JSON=/tmp/dna.json

  DESC
  task :client do
    chefistrano.run_chef_client
  end

end

Capistrano::Configuration.instance.chefistrano.search(:apps) do |app|
  Capistrano::Configuration.instance.namespace(app['id']) do
    app['revision'].each do |app_env, rev|
      namespace(app_env) do
        namespace :deploy do
          desc <<-DESC
          Deploy #{app['id']} to #{app_env}.  This calls 'update'.  Supply the \
          REVISION environment variable to specify the revison you want deployed.

          Sample usage:

            $ cap #{app['id']}:deploy REVISION=1.5.2
            $ cap #{app['id']}:deploy REVISION=1.5.34

          DESC
          task :default, :only => { :app_environment => app_env } do
            if ENV['REVISION'] && app['revision'][app_env] != ENV['REVISION']
              app['revision'][app_env] = ENV['REVISION']
              app.save
            end
            update
          end
          
          task :update, :roles => app['server_roles'], :only => { :app_environment => app_env } do
            log_level = ENV["LOG_LEVEL"] ? ENV["LOG_LEVEL"] : "info"
            cmd = "#{sudo} chef-client -l #{log_level}"
            tempfile = nil
            if ENV['JSON']
              tempfile = "/tmp/#{chefistrano.gen_temp_file_name}" 
              upload(ENV['JSON'], tempfile) 
              cmd << " -j #{ENV['JSON']}" 
            end
            run(cmd)
            run("#{sudo} rm #{tempfile}") if ENV['JSON']
          end

          desc <<-DESC
            Copy files to the currently deployed version. This is useful for updating \
            files piecemeal, such as when you need to quickly deploy only a single \
            file. Some files, such as updated templates, images, or stylesheets, \
            might not require a full deploy, and especially in emergency situations \
            it can be handy to just push the updates to production, quickly.

            To use this task, specify the files and directories you want to copy as a \
            comma-delimited list in the FILES environment variable. All directories \
            will be processed recursively, with all files being pushed to the \
            deployment servers.

              $ cap deploy:upload FILES=templates,controller.rb

            Dir globs are also supported:

            $ cap deploy:upload FILES='config/apache/*.conf'
          DESC
          task :upload, :except => { :no_release => true }, :only => { :app_environment => app_env } do
            files = (ENV["FILES"] || "").split(",").map { |f| Dir[f.strip] }.flatten
            abort "Please specify at least one file or directory to update (via the FILES environment variable)" if files.empty?

            files.each { |file| top.upload(file, File.join(app["deploy_to"], "current", file)) }
          end

        end
      end
    end
  end
end

