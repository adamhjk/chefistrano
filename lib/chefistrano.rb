require 'capistrano'
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

  def run
    run("chef-client")
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
      Capistrano::Configuration.instance.server server_fqdn, *node.run_list.roles  
    end
  end

  def search(index, query, sort=nil, start=0, rows=20, &block)
    q = Chef::Search::Query.new
    q.rest = rest
    if block
      q.search(index, query, sort, start, rows, &block)
    else
      q.search(index, query, sort, start, rows)
    end
  end

end

Chef::Config.from_file("/etc/chef/client.rb")
Chef::Log.level(:error)
Mixlib::Authentication::Log.level(:error)
Capistrano.plugin :chefistrano, Chefistrano 
Capistrano::Configuration.instance.chefistrano.setup

Capistrano::Configuration.instance.namespace(:chef) do

  desc <<-DESC
    Run the chef-client on the remote servers.  Use the ROLES environment \
    variable as a comma-delimited list of role names to run the command on, \
    or use the HOSTS environment variable.  

    Sample usage:

      $ cap chef:client ROLES=webserver
      $ cap chef:client ROLES=webserver,database
      $ cap chef:client HOSTS=foo.bar.com 

  DESC
  task :client do
    log_level = ENV["LOG_LEVEL"] ? ENV["LOG_LEVEL"] : "error"
    run("#{sudo} chef-client -l #{log_level}")
  end
end
