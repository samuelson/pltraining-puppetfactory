#! /usr/bin/env ruby

require 'rubygems'
require 'sinatra/base'
require 'webrick'
# require 'webrick/https'
# require 'openssl'
require 'resolv'
require 'json'
require 'fileutils'
require 'erb'
require 'yaml'
require 'puppetclassify'

AUTH_INFO = {
  "ca_certificate_path" => "/opt/puppet/share/puppet-dashboard/certs/ca_cert.pem",
  "certificate_path"    => "/opt/puppet/share/puppet-dashboard/certs/pe-internal-dashboard.cert.pem",
  "private_key_path"    => "/opt/puppet/share/puppet-dashboard/certs/pe-internal-dashboard.private_key.pem"
}

CLASSIFIER_URL = 'http://master.puppetlabs.vm:4433/classifier-api'

PUPPET    = '/opt/puppet/bin/puppet'
RAKE      = '/opt/puppet/bin/rake'
DASH_PATH = '/opt/puppet/share/puppet-dashboard'
RAKE_API  = "#{RAKE} -f #{DASH_PATH}/Rakefile RAILS_ENV=production"

DOCROOT   = '/opt/puppetfactory'            # where templates and public files go
LOGFILE   = '/var/log/puppetfactory'
CERT_PATH = 'certs'
USER      = 'admin'
PASSWORD  = 'admin'
CONTAINER_NAME = 'centosagent'

CONFDIR      = '/etc/puppetlabs/puppet'
ENVIRONMENTS = "#{CONFDIR}/environments"
USERSUFFIX   = 'puppetlabs.vm'

class Puppetfactory  < Sinatra::Base
    set :views, File.dirname(__FILE__) + '/../views'
    set :public_folder, File.dirname(__FILE__) + '/../public'

    configure :production, :development do
      enable :logging

      # why do I have to do this? This page implies I shouldn't.
      # https://github.com/sinatra/sinatra#logging
      set :logger,    WEBrick::Log::new(LOGFILE, WEBrick::Log::DEBUG)
      set :semaphore, Mutex.new
    end

    get '/' do
      erb :index
    end

    get '/home' do
      erb :home
    end

    get '/users' do
      protected!
      @users = load_users()
      erb :users
    end

    get '/login' do
      protected!
      erb :login
    end

    get '/new/:username' do |username|
      protected!
      create(username)
    end

    post '/new' do
      protected!
      create(params[:username], params[:password])
    end

    not_found do
      halt 404, 'page not found'
    end

    helpers do

      def load_users()
        status = {}
        users  = {}
        
        # build a quick list of all certificate statuses
        `/opt/puppet/bin/puppet cert list --all`.each_line do |line|
            certlist_name = line.split('"')[1]
            certlist_status = line =~ /\+/ ? "Certificate Signed" : "No Certificate Found"
            status[certlist_name] = certlist_status
        end        

        Dir.glob('/home/*').each do |path|
          username = File.basename path
          certname = "#{username}.#{USERSUFFIX}"
          console  = "#{username}@#{USERSUFFIX}"
          port     = "3" + `id -u #{username}`.chomp

          begin
            data    = YAML.load(`docker exec #{username} cat /var/opt/lib/pe-puppet/state/last_run_summary.yaml`)
            lastrun = Time.at(data['time']['last_run'])
          rescue Exception
            lastrun = :never
          end

          users[username] = {
            :status   => status[certname],
            :console  => console,
            :port     => port,
            :certname => certname,
            :lastrun  => lastrun,
          }
        end

        users
      end

      def create(username, password = 'puppet')
        begin
          adduser(username, password)
          skeleton(username)
          classify(username)
          sign(username)

          {:status => :success, :message => "Created user #{username}."}.to_json
        rescue Exception => e
          {:status => :failure, :message => e.message}.to_json
        end
      end

      def adduser(username, password)
        crypted = password.crypt("$5$a1")

        # ssh login user
        output = `adduser #{username} -p '#{crypted}' -G pe-puppet,docker -m 2>&1`
        raise "Could not create login user #{username}: #{output}" unless $? == 0

        # pe console user
        attributes = "display_name=#{username} roles=Operators email=#{username}@puppetlabs.vm password=#{password}"
        output     = `#{PUPPET} resource rbac_user #{username} ensure=present #{attributes} 2>&1`

        raise "Could not create PE Console user #{username}: #{output}" unless $? == 0
      end

      def skeleton(username)
        @username   = username
        @servername = `/bin/hostname`.chomp

        templates = "#{File.dirname(__FILE__)}/../templates"

        # configure environment
        FileUtils.mkdir_p "#{ENVIRONMENTS}/#{username}/manifests"
        FileUtils.mkdir_p "#{ENVIRONMENTS}/#{username}/modules"
        FileUtils.mkdir_p "/home/#{username}/share"

        File.open("#{ENVIRONMENTS}/#{username}/manifests/site.pp", 'w') do |f|
          f.write ERB.new(File.read("#{templates}/site.pp.erb")).result(binding)
        end
        
        File.open("/home/#{username}/share/puppet.conf","w") do |f|
          f.write ERB.new(File.read("#{templates}/puppet.conf.erb")).result(binding)
        end

        # make sure the user and pe-puppet can access all the needful
        FileUtils.chown_R username, 'pe-puppet', "#{ENVIRONMENTS}/#{username}"
        FileUtils.chmod 0750, "#{ENVIRONMENTS}/#{username}"

        # Set default login to attach to container
        File.open("/home/#{username}/.bashrc", 'w') do |bashrc|
          bashrc.puts "docker exec -it #{username} su -"
          bashrc.puts "exit 0"
        end

        # Get the uid of the new user and set up URL
        port = "3" + `id -u #{username}`.chomp

        # Create container with hostname set for username with port 80 mapped to 3000 + uid
        `docker run --add-host "master.puppetlabs.vm puppet:172.17.42.1" --name="#{username}" -p #{port}:80 -h #{username}.#{USERSUFFIX} -e RUNLEVEL=3 -d -v #{ENVIRONMENTS}/#{username}:/root/puppetcode -v /home/#{username}/share:/share -v /var/yum:/var/yum #{CONTAINER_NAME} /sbin/init`

        # Copy userprefs module into user environment
        `cp -r #{ENVIRONMENTS}/production/modules/userprefs #{ENVIRONMENTS}/#{username}/modules`
        `chown -R #{username}:pe-puppet #{ENVIRONMENTS}/#{username}`

        # Boot container to runlevel 3
        `docker exec #{username} /etc/rc`

        # Copy puppet.conf in place
        `docker exec #{username} cp -f /share/puppet.conf /etc/puppetlabs/puppet/puppet.conf`

      end

      def classify(username, groups=['no mcollective'])
        puppetclassify = PuppetClassify.new(CLASSIFIER_URL, AUTH_INFO)
        certname = "#{username}.#{USERSUFFIX}"
        groupstr = groups.join('\,')

        puppetclassify.groups.create_group({
          'name'               => certname,
          'environment'        => username,
          'environment_trumps' => true,
          'parent'             => '00000000-0000-4000-8000-000000000000',
          'classes'            => {},
          'rule'               => ['or', ['=', 'name', certname]]
        })
      end

      def sign(username)
        output = `docker exec #{username} puppet agent -t 2>&1`
        raise "Error creating certificates: #{output}, exit code #{$?}" unless $? == 256

        output = `#{PUPPET} cert sign #{username}.puppetlabs.vm 2>&1`
        raise "Error signing #{username}: #{output}" unless $? == 0
      end

      # Basic auth boilerplate
      def protected!
        unless authorized?
          response['WWW-Authenticate'] = %(Basic realm="Restricted Area")
          throw(:halt, [401, "Not authorized\n"])
        end
      end

      def authorized?
        @auth ||=  Rack::Auth::Basic::Request.new(request.env)
        @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials == [USER, PASSWORD]
      end

    end
end