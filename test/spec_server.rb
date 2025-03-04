# frozen_string_literal: true

require_relative 'helper'
require 'tempfile'
require 'socket'
require 'webrick'
require 'open-uri'
require 'net/http'
require 'net/https'

begin
  require 'stackprof'
  require 'tmpdir'
rescue LoadError
else
  test_profile = true
end

separate_testing do
  require_relative '../lib/rack/server'
  require_relative '../lib/rack/lint'
  require_relative '../lib/rack/mock'
  require_relative '../lib/rack/show_exceptions'
  require_relative '../lib/rack/tempfile_reaper'
  require_relative '../lib/rack/handler'
  require_relative '../lib/rack/handler/cgi'
end

describe Rack::Server do
  argv = Rack::Server::ARGV = []
  define_method(:argv) { argv }

  before { argv.clear }

  def app
    lambda { |env| [200, { 'content-type' => 'text/plain' }, ['success']] }
  end

  def with_stderr
    old, $stderr = $stderr, StringIO.new
    yield $stderr
  ensure
    $stderr = old
  end

  it "overrides :config if :app is passed in" do
    server = Rack::Server.new(app: "FOO")
    server.app.must_equal "FOO"
  end

  it "Options#parse parses -p and --port options into :Port" do
    Rack::Server::Options.new.parse!(%w[-p 1234]).must_equal :Port => '1234'
    Rack::Server::Options.new.parse!(%w[--port 1234]).must_equal :Port => '1234'
  end

  it "Options#parse parses -D and --daemonize option into :daemonize" do
    Rack::Server::Options.new.parse!(%w[-D]).must_equal :daemonize => true
    Rack::Server::Options.new.parse!(%w[--daemonize]).must_equal :daemonize => true
  end

  it "Options#parse parses --daemonize-noclose option into :daemonize => :noclose" do
    Rack::Server::Options.new.parse!(%w[--daemonize-noclose]).must_equal :daemonize => :noclose
    Rack::Server::Options.new.parse!(%w[-D --daemonize-noclose]).must_equal :daemonize => :noclose
    Rack::Server::Options.new.parse!(%w[--daemonize-noclose -D]).must_equal :daemonize => :noclose
  end

  it "Options#parse parses --profile option into :profile" do
    Rack::Server::Options.new.parse!(%w[--profile foo]).must_equal :profile_file => 'foo'
  end

  it "Options#parse parses --profile-mode option into :profile_mode" do
    Rack::Server::Options.new.parse!(%w[--profile-mode cpu]).must_equal :profile_mode => :cpu
  end

  it "Options#parse parses argument into :config" do
    Rack::Server::Options.new.parse!(%w[foo]).must_equal :config => 'foo'
  end

  it "Options#handler_opts doesn't include Host/Port options" do
    tester = Object.new
    def tester.valid_options
      {'Host: ' => 'anything', 'Port: ' => 'anything'}
    end
    def tester.to_s
      'HPOT'
    end
    def tester.name
      'HPOT'
    end
    Rack::Handler.const_set(:HPOT, tester)
    Rack::Handler.register(:host_port_option_tester, tester)
    Rack::Server::Options.new.handler_opts(server: :host_port_option_tester).must_equal ""
  end

  it "logging_middleware will include common logger except for CGI" do
    c = Class.new(Rack::Server)
    def c.middleware
      Hash.new{[logging_middleware]}
    end

    argv.replace(['-swebrick', '-b', 'run ->(env){[200, {}, []]}'])
    c.new.send(:wrapped_app).must_be_kind_of Rack::CommonLogger

    argv.replace(['-scgi', '-b', 'run ->(env){[200, {}, []]}'])
    c.new.send(:wrapped_app).must_be_kind_of Proc
  end

  it "#app aborts when config.ru file does not exist" do
    argv.replace(['-swebrick', 'non-existant.ru'])
    c = Class.new(Rack::Server) do
      alias abort raise
    end
    proc{c.new.app}.must_raise(RuntimeError).message.must_match(/\Aconfiguration .* not found\z/)
  end

  it "#app returns app when config.ru file exists" do
    argv.replace(['-swebrick', 'test/builder/line.ru'])
    Rack::Server.new.app.must_be_kind_of Proc
  end

  it "#start daemonizes if daemonize option is given" do
    server = Rack::Server.new(daemonize: true, app: proc{}, server: :cgi)
    def server.daemonize_app
      throw :foo, :bar
    end
    catch(:foo){server.start}.must_equal :bar
  end

  if test_profile
    it "#profiles to temp file if :profile_mode option is given and :profile_file option is not given" do
      server = Rack::Server.new(app: proc{[200, {}, []]}, server: :cgi, profile_mode: :cpu)
      output = String.new
      server.define_singleton_method(:puts){|str| output << str}
      def server.exit
        throw :foo, :bar
      end
      catch(:foo){server.start}.must_equal :bar
      filename = output.split.last
      File.file?(filename).must_equal true
      File.size(filename).must_be :>, 0
      File.delete(filename)
    end

    it "#profiles to given file if :profile_mode and :profile_file options are given" do
      Dir.mktmpdir('test-rack-') do |dir|
        filename = File.join(dir, 'profile')
        server = Rack::Server.new(app: proc{[200, {}, []]}, server: :cgi, profile_mode: :cpu, profile_file: filename)
        output = String.new
        server.define_singleton_method(:puts){|str| output << str}
        def server.exit
          throw :foo, :bar
        end
        catch(:foo){server.start}.must_equal :bar
        output.split.last.must_include 'profile'
        File.file?(filename).must_equal true
        File.size(filename).must_be :>, 0
        File.delete(filename)
      end
    end
  end

  it "clears arguments if ENV['REQUEST_METHOD'] is set" do
    begin
      ENV['REQUEST_METHOD'] = 'GET'
      argv.replace(%w[-scgi config.ru])
      Rack::Server.new
      argv.must_be_empty
    ensure
      ENV.delete('REQUEST_METHOD')
    end
  end

  it "prefer to use :builder when it is passed in" do
    server = Rack::Server.new(builder: "run lambda { |env| [200, {'content-type' => 'text/plain'}, ['success']] }")
    Rack::MockRequest.new(server.app).get("/").body.to_s.must_equal 'success'
  end

  it "allow subclasses to override middleware" do
    server = Class.new(Rack::Server).class_eval { def middleware; Hash.new [] end; self }
    server.middleware['deployment'].wont_equal []
    server.new(app: 'foo').middleware['deployment'].must_equal []
  end

  it "allow subclasses to override default middleware" do
    server = Class.new(Rack::Server).instance_eval { def default_middleware_by_environment; Hash.new [] end; self }
    server.middleware['deployment'].must_equal []
    server.new(app: 'foo').middleware['deployment'].must_equal []
  end

  it "only provide default middleware for development and deployment environments" do
    Rack::Server.default_middleware_by_environment.keys.sort.must_equal %w(deployment development)
  end

  it "always return an empty array for unknown environments" do
    server = Rack::Server.new(app: 'foo')
    server.middleware['production'].must_equal []
  end

  it "not include Rack::Lint in deployment environment" do
    server = Rack::Server.new(app: 'foo')
    server.middleware['deployment'].flatten.wont_include Rack::Lint
  end

  it "not include Rack::ShowExceptions in deployment environment" do
    server = Rack::Server.new(app: 'foo')
    server.middleware['deployment'].flatten.wont_include Rack::ShowExceptions
  end

  it "include Rack::TempfileReaper in deployment environment" do
    server = Rack::Server.new(app: 'foo')
    server.middleware['deployment'].flatten.must_include Rack::TempfileReaper
  end

  it "be quiet if said so" do
    server = Rack::Server.new(app: "FOO", quiet: true)
    Rack::Server.logging_middleware.call(server).must_be_nil
  end

  it "use a full path to the pidfile" do
    # avoids issues with daemonize chdir
    opts = Rack::Server.new.send(:parse_options, %w[--pid testing.pid])
    opts[:pid].must_equal ::File.expand_path('testing.pid')
  end

  it "get options from ARGV" do
    argv.replace(['--debug', '-sthin', '--env', 'production', '-w', '-q', '-o', 'localhost', '-O', 'NAME=VALUE', '-ONAME2', '-D'])
    server = Rack::Server.new
    server.options[:debug].must_equal true
    server.options[:server].must_equal 'thin'
    server.options[:environment].must_equal 'production'
    server.options[:warn].must_equal true
    server.options[:quiet].must_equal true
    server.options[:Host].must_equal 'localhost'
    server.options[:NAME].must_equal 'VALUE'
    server.options[:NAME2].must_equal true
    server.options[:daemonize].must_equal true
  end

  def test_options_server(*args)
    argv.replace(args)
    output = String.new
    Class.new(Rack::Server) do
      define_method(:opt_parser) do
        Class.new(Rack::Server::Options) do
          define_method(:puts) do |*args|
            output << args.join("\n") << "\n"
          end
          alias warn puts
          alias abort puts
          define_method(:exit) do
            output << "exited"
          end
        end.new
      end
    end.new
    output
  end

  it "support -h option to get help" do
    test_options_server('-scgi', '-h').must_match(/\AUsage: rackup.*Ruby options:.*Rack options.*Profiling options.*Common options.*exited\z/m)
  end

  it "support -h option to get handler-specific help" do
    cgi = Rack::Handler.get('cgi')
    begin
      def cgi.valid_options; { "FOO=BAR" => "BAZ" } end
      test_options_server('-scgi', '-h').must_match(/\AUsage: rackup.*Ruby options:.*Rack options.*Profiling options.*Common options.*Server-specific options for Rack::Handler::CGI.*-O +FOO=BAR +BAZ.*exited\z/m)
    ensure
      cgi.singleton_class.send(:remove_method, :valid_options)
    end
  end

  it "support -h option to display warning for invalid handler" do
    test_options_server('-sbanana', '-h').must_match(/\AUsage: rackup.*Ruby options:.*Rack options.*Profiling options.*Common options.*Warning: Could not find handler specified \(banana\) to determine handler-specific options.*exited\z/m)
  end

  it "support -v option to get version" do
    test_options_server('-v').must_match(/\ARack \d\.\d \(Release: \d+\.\d+\.\d+\)\nexited\z/)
  end

  it "warn for invalid --profile-mode option" do
    test_options_server('--profile-mode', 'foo').must_match(/\Ainvalid option: --profile-mode unknown profile mode: foo.*Usage: rackup/m)
  end

  it "warn for invalid options" do
    test_options_server('--banana').must_match(/\Ainvalid option: --banana.*Usage: rackup/m)
  end

  it "support -b option to specify inline rackup config" do
    argv.replace(['-scgi', '-E', 'development', '-b', 'use Rack::ContentLength; run ->(env){[200, {}, []]}'])
    server = Rack::Server.new
    server.server.singleton_class.send(:remove_method, :run)
    def (server.server).run(app, **) app end
    s, h, b = server.start.call('rack.errors' => StringIO.new)
    s.must_equal 500
    h['content-type'].must_equal 'text/plain'
    b.join.must_include 'Rack::Lint::LintError'
  end

  it "support -e option to evaluate ruby code" do
    argv.replace(['-scgi', '-e', 'Object::XYZ = 2'])
    begin
      Rack::Server.new
      Object::XYZ.must_equal 2
    ensure
      Object.send(:remove_const, :XYZ)
    end
  end

  it "abort if config file does not exist" do
    argv.replace(['-scgi'])
    server = Rack::Server.new
    def server.abort(s) throw :abort, s end
    message = catch(:abort) do
      server.start
    end
    message.must_match(/\Aconfiguration .*config\.ru not found/)
  end

  it "support -I option to change the load path and -r to require" do
    argv.replace(['-scgi', '-Ifoo/bar', '-Itest/load', '-rrack-test-a', '-rrack-test-b'])
    begin
      server = Rack::Server.new
      server.server.singleton_class.send(:remove_method, :run)
      def (server.server).run(*) end
      def server.handle_profiling(*) end
      def server.app(*) end
      server.start
      $LOAD_PATH.must_include('foo/bar')
      $LOAD_PATH.must_include('test/load')
      $LOADED_FEATURES.must_include(File.join(Dir.pwd, "test/load/rack-test-a.rb"))
      $LOADED_FEATURES.must_include(File.join(Dir.pwd, "test/load/rack-test-b.rb"))
    ensure
      $LOAD_PATH.delete('foo/bar')
      $LOAD_PATH.delete('test/load')
      $LOADED_FEATURES.delete(File.join(Dir.pwd, "test/load/rack-test-a.rb"))
      $LOADED_FEATURES.delete(File.join(Dir.pwd, "test/load/rack-test-b.rb"))
    end
  end

  it "support -w option to warn and -d option to debug" do
    argv.replace(['-scgi', '-d', '-w'])
    warn = $-w
    debug = $DEBUG
    begin
      server = Rack::Server.new
      server.server.singleton_class.send(:remove_method, :run)
      def (server.server).run(*) end
      def server.handle_profiling(*) end
      def server.app(*) end
      def server.p(*) end
      def server.pp(*) end
      def server.require(*) end
      server.start
      $-w.must_equal true
      $DEBUG.must_equal true
    ensure
      $-w = warn
      $DEBUG = debug
    end
  end

  if RUBY_ENGINE == "ruby"
    it "support --heap option for heap profiling" do
      begin
        require 'objspace'
      rescue LoadError
      else
        t = Tempfile.new
        begin
          argv.replace(['-scgi', '--heap', t.path, '-E', 'production', '-b', 'run ->(env){[200, {}, []]}'])
          server = Rack::Server.new
          server.server.singleton_class.send(:remove_method, :run)
          def (server.server).run(*) end
          def server.exit; throw :exit end
          catch :exit do
            server.start
          end
          File.file?(t.path).must_equal true
        ensure
          File.delete t.path
        end
      end
    end

    it "support --profile-mode option for stackprof profiling" do
      begin
        require 'stackprof'
      rescue LoadError
      else
        t = Tempfile.new
        begin
          argv.replace(['-scgi', '--profile', t.path, '--profile-mode', 'cpu', '-E', 'production', '-b', 'run ->(env){[200, {}, []]}'])
          server = Rack::Server.new
          def (server.server).run(*) end
          def server.puts(*) end
          def server.exit; throw :exit end
          catch :exit do
            server.start
          end
          File.file?(t.path).must_equal true
        ensure
          File.delete t.path
        end
      end
    end

    it "support --profile-mode option for stackprof profiling without --profile option" do
      begin
        require 'stackprof'
      rescue LoadError
      else
        begin
          argv.replace(['-scgi', '--profile-mode', 'cpu', '-E', 'production', '-b', 'run ->(env){[200, {}, []]}'])
          server = Rack::Server.new
          def (server.server).run(*) end
          filename = nil
          server.define_singleton_method(:make_profile_name) do |fname, &block|
            super(fname) do |fn|
              filename = fn
              block.call(filename)
            end
          end
          def server.puts(*) end
          def server.exit; throw :exit end
          catch :exit do
            server.start
          end
          File.file?(filename).must_equal true
        ensure
          File.delete filename
        end
      end
    end
  end

  it "support exit for INT signal when server does not respond to shutdown" do
    argv.replace(['-scgi'])
    server = Rack::Server.new
    server.server.singleton_class.send(:remove_method, :run)
    def (server.server).run(*) end
    def server.handle_profiling(*) end
    def server.app(*) end
    exited = false
    server.define_singleton_method(:exit) do
      exited = true
    end
    server.start
    exited.must_equal false
    Process.kill(:INT, $$)
    sleep 1 unless RUBY_ENGINE == 'ruby'
    exited.must_equal true
  end

  it "support support Server.start for starting" do
    argv.replace(['-scgi'])
    c = Class.new(Rack::Server) do
      def start(*) [self.class, :started] end
    end
    c.start.must_equal [c, :started]
  end


  it "run a server" do
    pidfile = Tempfile.open('pidfile') { |f| break f }
    FileUtils.rm pidfile.path
    server = Rack::Server.new(
      app: app,
      environment: 'none',
      pid: pidfile.path,
      Port: TCPServer.open('localhost', 0){|s| s.addr[1] },
      Host: 'localhost',
      Logger: WEBrick::Log.new(nil, WEBrick::BasicLog::WARN),
      AccessLog: [],
      daemonize: false,
      server: 'webrick'
    )
    t = Thread.new { server.start { |s| Thread.current[:server] = s } }
    t.join(0.01) until t[:server] && t[:server].status != :Stop
    body = if URI.respond_to?(:open)
             URI.open("http://localhost:#{server.options[:Port]}/") { |f| f.read }
           else
             open("http://localhost:#{server.options[:Port]}/") { |f| f.read }
           end
    body.must_equal 'success'

    Process.kill(:INT, $$)
    t.join
    open(pidfile.path) { |f| f.read.must_equal $$.to_s }
  end

  it "run a secure server" do
    pidfile = Tempfile.open('pidfile') { |f| break f }
    FileUtils.rm pidfile.path
    server = Rack::Server.new(
      app: app,
      environment: 'none',
      pid: pidfile.path,
      Port: TCPServer.open('localhost', 0){|s| s.addr[1] },
      Host: 'localhost',
      Logger: WEBrick::Log.new(nil, WEBrick::BasicLog::WARN),
      AccessLog: [],
      daemonize: false,
      server: 'webrick',
      SSLEnable: true,
      SSLCertName: [['CN', 'nobody'], ['DC', 'example']]
    )
    t = Thread.new { server.start { |s| Thread.current[:server] = s } }
    t.join(0.01) until t[:server] && t[:server].status != :Stop

    uri = URI.parse("https://localhost:#{server.options[:Port]}/")

    Net::HTTP.start("localhost", uri.port, use_ssl: true,
      verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|

      request = Net::HTTP::Get.new uri

      body = http.request(request).body
      body.must_equal 'success'
    end

    Process.kill(:INT, $$)
    t.join
    open(pidfile.path) { |f| f.read.must_equal $$.to_s }
  end if RUBY_VERSION >= "2.6"

  it "check pid file presence and running process" do
    pidfile = Tempfile.open('pidfile') { |f| f.write($$); break f }.path
    server = Rack::Server.new(pid: pidfile)
    with_stderr do |err|
      lambda { server.send(:check_pid!) }.must_raise SystemExit
      err.rewind
      output = err.read
      output.must_match(/already running \(pid: #{$$}, file: #{pidfile}\)/)
    end
  end

  it "check pid file presence and dead process" do
    dead_pid = `echo $$`.to_i
    pidfile = Tempfile.open('pidfile') { |f| f.write(dead_pid); break f }.path
    server = Rack::Server.new(pid: pidfile)
    server.send(:check_pid!)
    ::File.exist?(pidfile).must_equal false
  end

  it "check pid file presence and exited process" do
    pidfile = Tempfile.open('pidfile') { |f| break f }.path
    ::File.delete(pidfile)
    server = Rack::Server.new(pid: pidfile)
    server.send(:check_pid!)
  end

  it "check pid file presence and not owned process" do
    owns_pid_1 = (Process.kill(0, 1) rescue nil) == 1
    skip "cannot test if pid 1 owner matches current process (eg. docker/lxc)" if owns_pid_1
    pidfile = Tempfile.open('pidfile') { |f| f.write(1); break f }.path
    server = Rack::Server.new(pid: pidfile)
    with_stderr do |err|
      lambda { server.send(:check_pid!) }.must_raise SystemExit
      err.rewind
      output = err.read
      output.must_match(/already running \(pid: 1, file: #{pidfile}\)/)
    end
  end

  it "rewrite pid file when it does not reference a running process" do
    pidfile = Tempfile.open('pidfile') { |f| break f }.path
    server = Rack::Server.new(pid: pidfile)
    ::File.open(pidfile, 'w') { }
    server.send(:write_pid)
    ::File.read(pidfile).to_i.must_equal $$
  end

  it "not write pid file when it references a running process" do
    pidfile = Tempfile.open('pidfile') { |f| break f }.path
    ::File.delete(pidfile)
    server = Rack::Server.new(pid: pidfile)
    ::File.open(pidfile, 'w') { |f| f.write(1) }
    with_stderr do |err|
      lambda { server.send(:write_pid) }.must_raise SystemExit
      err.rewind
      output = err.read
      output.must_match(/already running \(pid: 1, file: #{pidfile}\)/)
    end
  end

  it "inform the user about existing pidfiles with running processes" do
    pidfile = Tempfile.open('pidfile') { |f| f.write(1); break f }.path
    server = Rack::Server.new(pid: pidfile)
    with_stderr do |err|
      lambda { server.start }.must_raise SystemExit
      err.rewind
      output = err.read
      output.must_match(/already running \(pid: 1, file: #{pidfile}\)/)
    end
  end

end
