require "mcollective/util/choria"
require "mcollective/util/tasks_support"

module MCollective
  module Agent
    class Bolt_task < RPC::Agent
      action "download" do
        reply[:downloads] = 0

        tasks = Util::Choria.new.tasks_support

        reply.fail!("Received empty or invalid task file specification", 3) unless request[:files]

        files = JSON.parse(request[:files])

        if tasks.cached?(files)
          reply[:downloads] = 0
        elsif tasks.download_files(files)
          reply[:downloads] = files.size
        else
          reply.fail!("Could not download task %s files: %s" % [request[:task], $!.to_s], 1)
        end
      end

      action "run_and_wait" do
        tasks = Util::Choria.new.tasks_support

        reply[:task_id] = request.uniqid

        task = {
          "task" => request[:task],
          "input_method" => request[:input_method],
          "input" => request[:input],
          "files" => JSON.parse(request[:files])
        }

        reply.fail!("Task %s is not available or does not match the specification" % task["task"], 3) unless tasks.cached?(task["files"])

        status = nil

        # Wait for near the timeout and on timeout give up and fetch the
        # status so users can get good replies that include how things are
        # near timeout
        begin
          Timeout.timeout(timeout - 2) do
            status = tasks.run_task_command(reply[:task_id], task)
          end
        rescue Timeout::Error
          status = tasks.task_status(reply[:task_id])
        ensure
          reply_task_status(status) if status
        end
      end

      action "run_no_wait" do
        tasks = Util::Choria.new.tasks_support

        reply[:task_id] = request.uniqid

        task = {
          "task" => request[:task],
          "input_method" => request[:input_method],
          "input" => request[:input],
          "files" => JSON.parse(request[:files])
        }

        status = tasks.run_task_command(reply[:task_id], task)

        unless status["wrapper_spawned"]
          reply.fail!("Could not spawn task %s: %s" % [request[:task], status["wrapper_error"]])
        end
      end

      action "task_status" do
        tasks = Util::Choria.new.tasks_support

        status = tasks.task_status(request[:task_id])
        reply_task_status(status)

        unless status["wrapper_spawned"]
          reply.fail!("Could not spawn task %s: %s" % [request[:task], status["wrapper_error"]])
        end
      end

      def reply_task_status(status)
        reply[:exitcode] = status["exitcode"]
        reply[:stdout] = status["stdout"]
        reply[:stderr] = status["stderr"]
        reply[:completed] = status["completed"]
        reply[:runtime] = status["runtime"]
        reply[:start_time] = status["start_time"].to_i

        reply.fail("Task failed", 1) if status["exitcode"] != 0 && status["completed"]
      end
    end
  end
end