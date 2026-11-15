require "./assertions"

module Minitest
  module LifecycleHooks
    def before_setup
    end

    def setup
    end

    def after_setup
    end

    def before_teardown
    end

    def teardown
    end

    def after_teardown
    end

    # Runs once, with the first test this run executes for the class. Its failures
    # are recorded on that test. Tests sharing state set up here must use class
    # level state (constants or class variables): every test is a new instance.
    def __minitest_before_all
    end

    # Runs once, with the last test this run executes for the class. A fail-fast
    # stop also runs it for a suite it cut short, on a fresh instance.
    def __minitest_after_all
    end
  end

  class Test < Runnable
    include LifecycleHooks
    include Assertions

    def run_one(name : String, proc : Test ->) : Nil
      return unless should_run?(name)

      result = Result.new(self.class.name, name)

      capture_exception(result) { __minitest_before_all } if Minitest.hook_first?(self.class)

      result.time = Time.measure do
        capture_exception(result) do
          before_setup
          setup
          after_setup
          proc.call(self)
        end

        capture_exception(result) { before_teardown }
        capture_exception(result) { teardown }
        capture_exception(result) { after_teardown }
      end

      capture_exception(result) { __minitest_after_all } if Minitest.hook_last?(self.class)

      __reporter.record(result)

      if __reporter.options.fail_fast? && !result.passed? && !result.skipped?
        Minitest.stop!
      end
    end

    def capture_exception(result : Result, &) : Nil
      yield
    rescue ex : Assertion | Skip
      result.failures << ex
    rescue ex : Exception
      result.failures << UnexpectedError.new(ex)
    end

    @@failures = [] of Assertion | Skip | UnexpectedError

    def self.failures : Array(Assertion, Skip, UnexpectedError)
      @@failures
    end
  end
end
