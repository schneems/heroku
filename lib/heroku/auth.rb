require "heroku"
require "heroku/client"
require "heroku/helpers"
require "netrc"

class Heroku::Auth
  class << self
    include Heroku::Helpers

    attr_accessor :credentials

    def client
      @client ||= begin
        client = Heroku::Client.new(user, password, host)
        client.on_warning { |msg| self.display("\n#{msg}\n\n") }
        client
      end
    end

    def login
      delete_credentials
      get_credentials
    end

    def logout
      delete_credentials
    end

    # just a stub; will raise if not authenticated
    def check
      client.list
    end

    def default_host
      "heroku.com"
    end

    def host
      ENV['HEROKU_HOST'] || default_host
    end

    def reauthorize
      @credentials = ask_for_and_save_credentials
    end

    def user    # :nodoc:
      get_credentials[0]
    end

    def password    # :nodoc:
      get_credentials[1]
    end

    def api_key
      Heroku::Client.auth(user, password)["api_key"]
    end

    def get_credentials    # :nodoc:
      @credentials ||= (read_credentials || ask_for_and_save_credentials)
    end

    def delete_credentials
      FileUtils.rm_f(legacy_credentials_path) # delete legacy credentials, if any exist
      if netrc
        netrc.delete("api.#{host}")
        netrc.delete("code.#{host}")
        netrc.save
      end
      @client, @credentials = nil, nil
    end

    def legacy_credentials_path
      if host == default_host
        "#{home_directory}/.heroku/credentials"
      else
        "#{home_directory}/.heroku/credentials.#{CGI.escape(host)}"
      end
    end

    def netrc_path
      if running_on_windows?
        "#{home_directory}/_netrc"
      else
        "#{home_directory}/.netrc"
      end
    end

    def netrc   # :nodoc:
      @netrc ||= begin
        File.exists?(netrc_path) && Netrc.read(netrc_path)
      rescue => error
        if error.message =~ /^Permission bits for/
          perm = File.stat(netrc_path).mode & 0777
          abort("Permissions #{perm} for '#{netrc_path}' are too open. You should run `chmod 0600 #{netrc_path}` so that your credentials are NOT accessible by others.")
        else
          raise error
        end
      end
    end

    def read_credentials
      if ENV['HEROKU_API_KEY']
        ['', ENV['HEROKU_API_KEY']]
      else
        # convert legacy credentials to netrc
        if File.exists?(legacy_credentials_path)
          @client = nil
          @credentials = File.read(legacy_credentials_path).split("\n")
          write_credentials
          FileUtils.rm_f(legacy_credentials_path)
        end

        # read netrc credentials if they exist
        if netrc
          # force migration of long api tokens (80 chars) to short ones (40)
          # #write_credentials rewrites both api.* and code.*
          credentials = netrc["api.#{host}"]
          if credentials && credentials[1].length > 40
            @credentials = [ credentials[0], credentials[1][0,40] ]
            write_credentials
          end

          netrc["api.#{host}"]
        end
      end
    end

    def write_credentials
      FileUtils.mkdir_p(File.dirname(netrc_path))
      FileUtils.touch(netrc_path)
      unless running_on_windows?
        FileUtils.chmod(0600, netrc_path)
      end
      netrc["api.#{host}"] = self.credentials
      netrc["code.#{host}"] = self.credentials
      netrc.save
    end

    def echo_off
      with_tty do
        system "stty -echo"
      end
    end

    def echo_on
      with_tty do
        system "stty echo"
      end
    end

    def ask_for_credentials
      puts "Enter your Heroku credentials."

      print "Email: "
      user = ask

      print "Password: "
      password = running_on_windows? ? ask_for_password_on_windows : ask_for_password
      api_key = Heroku::Client.auth(user, password)['api_key']

      [user, api_key]
    end

    def ask_for_password_on_windows
      require "Win32API"
      char = nil
      password = ''

      while char = Win32API.new("crtdll", "_getch", [ ], "L").Call do
        break if char == 10 || char == 13 # received carriage return or newline
        if char == 127 || char == 8 # backspace and delete
          password.slice!(-1, 1)
        else
          # windows might throw a -1 at us so make sure to handle RangeError
          (password << char.chr) rescue RangeError
        end
      end
      puts
      return password
    end

    def ask_for_password
      echo_off
      password = ask
      puts
      echo_on
      return password
    end

    def ask_for_and_save_credentials
      begin
        @credentials = ask_for_credentials
        write_credentials
        check
      rescue ::RestClient::Unauthorized, ::RestClient::ResourceNotFound => e
        delete_credentials
        display "Authentication failed."
        retry if retry_login?
        exit 1
      rescue Exception => e
        delete_credentials
        raise e
      end
      check_for_associated_ssh_key unless Heroku::Command.current_command == "keys:add"
      @credentials
    end

    def check_for_associated_ssh_key
      return unless client.keys.empty?
      associate_or_generate_ssh_key
    end

    def associate_or_generate_ssh_key
      public_keys = Dir.glob("#{home_directory}/.ssh/*.pub").sort

      case public_keys.length
      when 0 then
        display "Could not find an existing public key."
        display "Would you like to generate one? [Yn] ", false
        unless ask.strip.downcase == "n"
          display "Generating new SSH public key."
          generate_ssh_key("id_rsa")
          associate_key("#{home_directory}/.ssh/id_rsa.pub")
        end
      when 1 then
        display "Found existing public key: #{public_keys.first}"
        associate_key(public_keys.first)
      else
        display "Found the following SSH public keys:"
        public_keys.each_with_index do |key, index|
          display "#{index+1}) #{File.basename(key)}"
        end
        display "Which would you like to use with your Heroku account? ", false
        chosen = public_keys[ask.to_i-1] rescue error("Invalid choice")
        associate_key(chosen)
      end
    end

    def generate_ssh_key(keyfile)
      ssh_dir = File.join(home_directory, ".ssh")
      unless File.exists?(ssh_dir)
        FileUtils.mkdir_p ssh_dir
        unless running_on_windows?
          File.chmod(0700, ssh_dir)
        end
      end
      `ssh-keygen -t rsa -N "" -f \"#{home_directory}/.ssh/#{keyfile}\" 2>&1`
    end

    def associate_key(key)
      display "Uploading SSH public key #{key}"
      client.add_key(File.read(key))
    end

    def retry_login?
      @login_attempts ||= 0
      @login_attempts += 1
      @login_attempts < 3
    end
  end
end
