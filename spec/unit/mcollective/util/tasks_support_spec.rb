require "spec_helper"
require "mcollective/util/choria"
require "mcollective/util/tasks_support"

module MCollective
  module Util
    describe TasksSupport do
      let(:cache) { "/tmp/tasks-cache-#{$$}" }
      let(:choria) { Choria.new(false) }
      let(:ts) { TasksSupport.new(choria, cache) }
      let(:tasks_fixture) { JSON.parse(File.read("spec/fixtures/tasks/tasks_list.json")) }
      let(:task_fixture) { JSON.parse(File.read("spec/fixtures/tasks/choria_ls_metadata.json")) }
      let(:task_fixture_rb) { File.read("spec/fixtures/tasks/choria_ls.rb") }
      let(:file) { task_fixture["files"].first }
      let(:task_run_request_fixture) { JSON.parse(File.read("spec/fixtures/tasks/task_run_request.json")) }

      before(:each) do
        choria.stubs(:puppet_server).returns(:target => "stubpuppet", :port => 8140)
        choria.stubs(:check_ssl_setup).returns(true)
      end

      after(:all) do
        FileUtils.rm_rf("/tmp/tasks-cache-#{$$}")
      end

      describe "#task_runtime" do
        it "should support succesfully completed tasks" do
          ts.stubs(:request_spooldir).returns("spec/fixtures/tasks/completed_spool")

          t = Time.now
          FileUtils.touch(File.join("spec/fixtures/tasks/completed_spool", "wrapper_pid"), :mtime => t - 60)
          FileUtils.touch(File.join("spec/fixtures/tasks/completed_spool", "exitcode"), :mtime => t - 40)

          expect(ts.task_runtime("x")).to eq(20.0)
        end

        it "should support wrapper failures" do
          ts.stubs(:request_spooldir).returns("spec/fixtures/tasks/wrapper_failed_spool")
          expect(ts.task_runtime("x")).to eq(0.0)
        end

        it "should support ongoing tasks" do
          ts.stubs(:request_spooldir).returns("spec/fixtures/tasks/still_running_spool")
          File::Stat.expects(:new).with("spec/fixtures/tasks/still_running_spool/wrapper_pid").returns(stub(:mtime => Time.now - 1))
          expect(ts.task_runtime("x")).to be_within(0.1).of(1.0)
        end
      end

      describe "#task_status" do
        it "should report failed wrapper invocations" do
          spool = File.expand_path("spec/fixtures/tasks/wrapper_failed_spool")
          ts.stubs(:request_spooldir).returns(spool)

          status = ts.task_status("test1")

          err = <<-ERROR
terminate called after throwing an instance of 'leatherman::json_container::data_key_error'
  what():  unknown object entry with key: executable
ERROR

          expect(status).to eq(
            "spool" => spool,
            "stdout" => "",
            "stderr" => "",
            "exitcode" => 127,
            "runtime" => 0.0,
            "start_time" => Time.at(0),
            "wrapper_spawned" => false,
            "wrapper_error" => err,
            "wrapper_pid" => nil,
            "completed" => true
          )
        end

        it "should correctly report a still running task" do
          spool = File.expand_path("spec/fixtures/tasks/still_running_spool")
          ts.stubs(:request_spooldir).returns(spool)
          ts.stubs(:task_runtime).returns(10)

          status = ts.task_status("test1")

          expect(status).to eq(
            "spool" => spool,
            "stdout" => File.read(File.join(spool, "stdout")),
            "stderr" => "",
            "exitcode" => 127,
            "runtime" => 10,
            "start_time" => File::Stat.new(File.join(spool, "wrapper_pid")).mtime,
            "wrapper_spawned" => true,
            "wrapper_error" => "",
            "wrapper_pid" => 2493,
            "completed" => false
          )
        end

        it "should correctly report a completed task" do
          spool = File.expand_path("spec/fixtures/tasks/completed_spool")
          ts.stubs(:request_spooldir).returns(spool)

          t = Time.now
          FileUtils.touch(File.join(spool, "wrapper_pid"), :mtime => t - 60)
          FileUtils.touch(File.join(spool, "exitcode"), :mtime => t - 40)

          status = ts.task_status("test1")

          expect(status).to eq(
            "spool" => spool,
            "stdout" => File.read(File.join(spool, "stdout")),
            "stderr" => "",
            "exitcode" => 0,
            "runtime" => 20.0,
            "start_time" => File::Stat.new(File.join(spool, "wrapper_pid")).mtime,
            "wrapper_spawned" => true,
            "wrapper_error" => "",
            "wrapper_pid" => 2493,
            "completed" => true
          )
        end
      end

      describe "#run_task_command" do
        it "should spawn the right command and wait" do
          File.stubs(:exist?).with(ts.wrapper_path).returns(true)
          ts.stubs(:request_spooldir).returns(File.join(cache, "test_1"))
          ts.expects(:spawn_command).with(
            "/opt/puppetlabs/puppet/bin/task_wrapper",
            {},
            instance_of(String),
            File.join(cache, "test_1")
          )

          ts.stubs(:cached?).returns(true)
          ts.expects(:wait_for_task_completion)
          ts.stubs(:task_status)

          ts.run_task_command("test_1", task_run_request_fixture)
        end
      end

      describe "#task_complete?" do
        it "should report completion correctly" do
          ts.stubs(:request_spooldir).with("spawn_test_1").returns(File.join(cache, "spawn_test_1"))

          FileUtils.mkdir_p(ts.request_spooldir("spawn_test_1"))
          exitcode = File.join(ts.request_spooldir("spawn_test_1"), "exitcode")

          expect(ts.task_complete?("spawn_test_1")).to be(false)

          FileUtils.touch(exitcode)

          expect(ts.task_complete?("spawn_test_1")).to be(false)

          File.open(exitcode, "w") {|f| f.puts "1"}

          expect(ts.task_complete?("spawn_test_1")).to be(true)
        end

        it "should support wrapper failures" do
          spool = File.join(cache, "spawn_test_1")

          ts.stubs(:request_spooldir).with("spawn_test_1").returns(spool)
          FileUtils.mkdir_p(spool)

          File.open(File.join(spool, "wrapper_stderr"), "w") {|f| f.puts "wrapper failed"}
          File.expects(:exist?).with(File.join(spool, "wrapper_stderr")).returns(true)

          expect(ts.task_complete?("spawn_test_1")).to be(true)
        end
      end

      describe "#wait_for_task_completion" do
        it "should wait until the file appears" do
          ts.expects(:task_complete?).with("spawn_test_2").returns(false, true).twice
          ts.wait_for_task_completion("spawn_test_2")
        end
      end

      describe "#spawn_command" do
        it "should run the command and write all the right files" do
          FileUtils.mkdir_p(spool = File.join(cache, "spawn_test_1"))

          pid = ts.spawn_command("/bin/cat", {}, "hello world", spool)

          Timeout.timeout(1) do
            sleep 0.1 until File::Stat.new(File.join(spool, "wrapper_stdout")).size > 0 # rubocop:disable Style/ZeroLengthPredicate
          end

          expect(File.read(File.join(spool, "wrapper_stderr"))).to eq("")
          expect(File.read(File.join(spool, "wrapper_stdin"))).to eq("hello world")
          expect(File.read(File.join(spool, "wrapper_stdout"))).to eq("hello world")
          expect(File.read(File.join(spool, "wrapper_pid"))).to eq(pid.to_s)
        end

        it "should set environment" do
          FileUtils.mkdir_p(spool = File.join(cache, "spawn_test_2"))

          pid = ts.spawn_command("/bin/cat /proc/self/environ", {"RSPEC_TEST" => "hello world"}, nil, spool)

          Timeout.timeout(1) do
            sleep 0.1 until File::Stat.new(File.join(spool, "wrapper_stdout")).size > 0 # rubocop:disable Style/ZeroLengthPredicate
          end

          expect(File.read(File.join(spool, "wrapper_stderr"))).to eq("")
          expect(File.read(File.join(spool, "wrapper_stdout"))).to include("RSPEC_TEST=hello world")
          expect(File.read(File.join(spool, "wrapper_pid"))).to eq(pid.to_s)
        end
      end

      describe "#task_input" do
        it "should return the input for both, powershell and stdin methods" do
          expect(ts.task_input(task_run_request_fixture)).to eq(task_run_request_fixture["input"])
        end

        it "should return nil otherwise" do
          task_run_request_fixture["input_method"] = "environment"
          expect(ts.task_input(task_run_request_fixture)).to be_nil
        end
      end

      describe "#create_request_spooldir" do
        it "should create a spooldir with the right name and permissions" do
          choria.stubs(:tasks_spool_dir).returns(cache)
          dir = ts.create_request_spooldir("1234567890")

          expect(dir).to eq(File.join(cache, "1234567890"))
          expect(File.directory?(dir)).to be(true)
          expect(File::Stat.new(dir).mode).to eq(0o040750)
        end
      end

      describe "#task_environment" do
        it "should set the environment for both or environment methods" do
          ["both", "environment"].each do |method|
            task_run_request_fixture["input_method"] = method
            expect(ts.task_environment(task_run_request_fixture)).to eq("PT_directory" => "/tmp")
          end
        end

        it "should not set it otherwise" do
          ["powershell", "stdin"].each do |method|
            task_run_request_fixture["input_method"] = method
            expect(ts.task_environment(task_run_request_fixture)).to be_empty
          end
        end
      end

      describe "#task_command" do
        it "should support powershell input method" do
          task_run_request_fixture["input_method"] = "powershell"
          task_run_request_fixture["files"][0]["filename"] = "test.ps1"

          expect(ts.task_command(task_run_request_fixture)).to eq(
            [
              "/opt/puppetlabs/puppet/bin/PowershellShim.ps1",
              "#{cache}/f3b4821836cf7fe6fe17dfb2924ff6897eba43a44cc4cba0e0ed136b27934ede/test.ps1"
            ]
          )
        end

        it "should use the platform specific command otherwise" do
          expect(ts.task_command(task_run_request_fixture)).to eq(["#{cache}/f3b4821836cf7fe6fe17dfb2924ff6897eba43a44cc4cba0e0ed136b27934ede/ls.rb"])
        end
      end

      describe "#task_input_method" do
        it "should support a specifically given input method" do
          expect(ts.task_input_method(task_run_request_fixture)).to eq("stdin")
        end

        it "should use powershell when not given and its a ps1 file" do
          task_run_request_fixture.delete("input_method")
          task_run_request_fixture["files"][0]["filename"] = "test.ps1"
          expect(ts.task_input_method(task_run_request_fixture)).to eq("powershell")
        end

        it "should default to both otherwise" do
          task_run_request_fixture.delete("input_method")
          expect(ts.task_input_method(task_run_request_fixture)).to eq("both")
        end
      end

      describe "#cached?" do
        before(:each) do
          files = task_fixture["files"]
          files << files[0].dup
          files[1]["filename"] = "file2.rb"
        end

        it "should pass on all good files" do
          ts.expects(:task_file?).with(has_entries("filename" => "ls.rb")).returns(true)
          ts.expects(:task_file?).with(has_entries("filename" => "file2.rb")).returns(true)

          expect(ts.cached?(task_fixture["files"])).to be(true)
        end

        it "should fail on some failed files" do
          ts.expects(:task_file?).with(has_entries("filename" => "ls.rb")).returns(true)
          ts.expects(:task_file?).with(has_entries("filename" => "file2.rb")).returns(false)

          expect(ts.cached?(task_fixture["files"])).to be(false)
        end
      end

      describe "#platform_specific_command" do
        it "should use the path directly on nix" do
          Util.stubs(:windows?).returns(false)
          expect(ts.platform_specific_command("/some/script")).to eq(["/some/script"])
        end

        context "on windows" do
          before(:each) { Util.stubs(:windows?).returns(true) }

          it "should support rb scripts" do
            expect(ts.platform_specific_command("foo.rb")).to eq(%w[ruby foo.rb])
          end

          it "should support pp scripts" do
            expect(ts.platform_specific_command("foo.pp")).to eq(%w[puppet apply foo.pp])
          end

          it "should support powershell scripts" do
            expect(ts.platform_specific_command("foo.ps1")).to eq(%w[powershell -NoProfile -NonInteractive -NoLogo -ExecutionPolicy Bypass -File foo.ps1])
          end

          it "should try the executable directly" do
            expect(ts.platform_specific_command("foo.exe")).to eq(["foo.exe"])
          end
        end
      end

      describe "#ps_shim_path" do
        it "should be relative to bin_path" do
          ts.stubs(:bin_path).returns("/nonexisting/bin")
          expect(ts.ps_shim_path).to eq("/nonexisting/bin/PowershellShim.ps1")
        end
      end

      describe "#bin_path" do
        it "should support windows" do
          Util.stubs(:windows?).returns(true)
          expect(ts.bin_path).to eq('C:\Program Files\Puppet Labs\Puppet\bin')
        end

        it "should support nix" do
          expect(ts.bin_path).to eq("/opt/puppetlabs/puppet/bin")
        end
      end

      describe "#tasks" do
        it "should retrieve the tasks" do
          stub_request(:get, "https://stubpuppet:8140/puppet/v3/tasks?environment=production")
            .to_return(:status => 200, :body => tasks_fixture.to_json)

          expect(ts.tasks("production")).to eq(tasks_fixture)
        end
      end

      describe "#task_names" do
        it "should retrieve the right task names" do
          stub_request(:get, "https://stubpuppet:8140/puppet/v3/tasks?environment=production")
            .to_return(:status => 200, :body => tasks_fixture.to_json)

          expect(ts.task_names("production")).to eq(["choria::ls", "puppet_conf"])
        end
      end

      describe "#download_files" do
        it "should download every file" do
          files = task_fixture["files"]
          files << files[0].dup
          files[1]["filename"] = "file2.rb"

          ts.expects(:task_file?).with(files[0]).returns(true).once
          ts.expects(:task_file?).with(files[1]).returns(true).once

          ts.expects(:cache_task_file).never

          expect(ts.download_files(files)).to be(true)
        end

        it "should support retries" do
          ts.expects(:cache_task_file).with(file).raises("test failure").then.returns(true).twice
          ts.expects(:task_file?).with(file).returns(false)
          expect(ts.download_files(task_fixture["files"])).to be(true)
        end

        it "should attempt twice and fail after" do
          ts.expects(:cache_task_file).with(file).raises("test failure").twice
          ts.stubs(:task_file?).returns(false)
          expect do
            ts.download_files(task_fixture["files"])
          end.to raise_error("Could not download task file: RuntimeError: test failure")
        end
      end

      describe "#cache_task_file" do
        before(:each) do
          FileUtils.rm_rf(cache)
        end

        it "should download and cache the file" do
          expect(ts.task_file?(file)).to be(false)

          stub_request(:get, "https://stubpuppet:8140/puppet/v3/file_content/tasks/choria/ls.rb?environment=production")
            .with(:headers => {"Accept" => "application/octet-stream"})
            .to_return(:status => 200, :body => task_fixture_rb)

          ts.cache_task_file(file)

          assert_requested(:get, "https://stubpuppet:8140/puppet/v3/file_content/tasks/choria/ls.rb?environment=production", :times => 1)

          expect(ts.task_file?(file)).to be(true)
        end

        it "should handle failures" do
          expect(ts.task_file?(file)).to be(false)

          stub_request(:get, "https://stubpuppet:8140/puppet/v3/file_content/tasks/choria/ls.rb?environment=production")
            .with(:headers => {"Accept" => "application/octet-stream"})
            .to_return(:status => 404, :body => "not found")

          expect do
            ts.cache_task_file(file)
          end.to raise_error("Failed to request task content /puppet/v3/file_content/tasks/choria/ls.rb?environment=production: 404: not found")

          assert_requested(:get, "https://stubpuppet:8140/puppet/v3/file_content/tasks/choria/ls.rb?environment=production", :times => 1)

          expect(ts.task_file?(file)).to be(false)
        end
      end

      describe "#task_file" do
        it "should fail if the dir does not exist" do
          File.expects(:directory?).with(ts.task_dir(file)).returns(false)
          expect(ts.task_file?(file)).to be(false)
        end

        it "should fail if the file does not exist" do
          File.expects(:directory?).with(ts.task_dir(file)).returns(true)
          File.expects(:exist?).with(ts.task_file_name(file)).returns(false)
          expect(ts.task_file?(file)).to be(false)
        end

        it "should fail if the file has the wrong size" do
          File.expects(:directory?).with(ts.task_dir(file)).returns(true)
          File.expects(:exist?).with(ts.task_file_name(file)).returns(true)
          ts.expects(:file_size).with(ts.task_file_name(file)).returns(1)
          expect(ts.task_file?(file)).to be(false)
        end

        it "should fail if the file has the wrong sha256" do
          File.expects(:directory?).with(ts.task_dir(file)).returns(true)
          File.expects(:exist?).with(ts.task_file_name(file)).returns(true)
          ts.expects(:file_size).with(ts.task_file_name(file)).returns(149)
          ts.expects(:file_sha256).with(ts.task_file_name(file)).returns("")

          expect(ts.task_file?(file)).to be(false)
        end

        it "should pass for correct files" do
          File.expects(:directory?).with(ts.task_dir(file)).returns(true)
          File.expects(:exist?).with(ts.task_file_name(file)).returns(true)
          ts.expects(:file_size).with(ts.task_file_name(file)).returns(149)
          ts.expects(:file_sha256).with(ts.task_file_name(file)).returns("f3b4821836cf7fe6fe17dfb2924ff6897eba43a44cc4cba0e0ed136b27934ede")

          expect(ts.task_file?(file)).to be(true)
        end
      end

      describe "#file_size" do
        it "should calculate the correct size" do
          expect(ts.file_size("spec/fixtures/tasks/choria_ls_metadata.json")).to eq(569)
        end
      end

      describe "#file_sha256" do
        it "should calculate the right sha256" do
          expect(ts.file_sha256("spec/fixtures/tasks/choria_ls_metadata.json")).to eq("9c98b23902538c0c1483eee76f14c9b96320289a82b9f848cdc3d17e4802e195")
        end
      end

      describe "#task_metadata" do
        it "should fetch and decode the task metadata" do
          stub_request(:get, "https://stubpuppet:8140/puppet/v3/tasks/choria/ls?environment=production")
            .to_return(:status => 200, :body => task_fixture.to_json)

          expect(ts.task_metadata("choria::ls", "production")).to eq(task_fixture)
        end

        it "should handle failures correctly" do
          stub_request(:get, "https://stubpuppet:8140/puppet/v3/tasks/choria/ls?environment=production")
            .to_return(:status => 404, :body => "Could not find module 'choria'")

          expect do
            ts.task_metadata("choria::ls", "production")
          end.to raise_error("Failed to request task metadata: 404: Could not find module 'choria'")
        end
      end

      describe "#http_get" do
        it "should retrieve a file from the puppetserver" do
          stub_request(:get, "https://stubpuppet:8140/test")
            .with(:headers => {"Test-Header" => "true"})
            .to_return(:status => 200, :body => "Test OK")

          expect(ts.http_get("/test", "Test-Header" => true).body).to eq("Test OK")
        end
      end

      describe "#task_file_name" do
        it "should determine the correct file name" do
          expect(ts.task_file_name(task_fixture["files"][0])).to eq(File.join(cache, "f3b4821836cf7fe6fe17dfb2924ff6897eba43a44cc4cba0e0ed136b27934ede", "ls.rb"))
        end
      end

      describe "#task_dir" do
        it "should determine the correct directory" do
          expect(ts.task_dir(task_fixture["files"][0])).to eq(File.join(cache, "f3b4821836cf7fe6fe17dfb2924ff6897eba43a44cc4cba0e0ed136b27934ede"))
        end
      end

      describe "#parse_task" do
        it "should detect modulename only tasks" do
          expect(ts.parse_task("choria")).to eq(["choria", "init"])
        end

        it "should parse correctly" do
          expect(ts.parse_task("choria::task")).to eq(["choria", "task"])
        end
      end
    end
  end
end