require "option_parser"
require "./result"
require "./reporter"
require "./runnable"
require "./test"
require "./spec"

module Minitest
  class Options
    property? chaos : Bool
    property? verbose : Bool
    property? fail_fast : Bool
    property fibers : Int32
    getter pattern : String | Regex | Nil
    getter seed : UInt32
    property? junit : String?
    property? color : Bool = Colorize.enabled?
    # A single line to select, or the declaration's it..end range for FILE:LINE.
    property line : Int32?
    property location : Runnable::Location?
    # Tags the run requires (positive) or forbids (~negative); repeatable.
    getter tags : Array(String)

    def initialize
      @chaos = false
      @verbose = false
      @fail_fast = false
      @fibers = 1
      @line = nil
      @location = nil
      @tags = [] of String
      @seed = ENV["SEED"]?.try(&.to_u32) || Random.rand(0_u32..0xFFFF_u32)
    end

    def pattern=(pattern : String)
      if pattern =~ %r(\A/(.+?)/\Z)
        @pattern = Regex.new($1)
      else
        @pattern = pattern
      end
    end

    def seed=(seed : String | UInt32)
      @seed = seed.to_u32
    end

    # Each --tag appends: a tag with a leading ~ forbids it, any other requires it.
    def tags=(tag : String) : Nil
      @tags << tag
    end

    # The test name, its class name, or "Class#test_name" (what a failure prints)
    # all match --name. Selecting by describe title is the point: the mangled
    # method name is unguessable with punctuation in the title.
    def selects_name?(class_name : String, name : String) : Bool
      case pattern = @pattern
      when Regex
        !(name =~ pattern).nil? || !(class_name =~ pattern).nil? || !("#{class_name}##{name}" =~ pattern).nil?
      when String
        name == pattern || class_name == pattern || "#{class_name}##{name}" == pattern
      else
        true
      end
    end

    def selects_location?(location : Runnable::Location) : Bool
      file, first_line, last_line = location

      if target = @location
        return false if file.empty?
        target_file, target_line, _ = target
        return false unless file == target_file || file.ends_with?("/#{target_file}")
        return false unless target_line >= first_line && target_line <= last_line
      end

      if line = @line
        return false if file.empty?
        return false unless line >= first_line && line <= last_line
      end

      true
    end

    def selects_tags?(tags : Set(String)) : Bool
      return true if @tags.empty?

      @tags.all? do |tag|
        if tag.starts_with?('~')
          !tags.includes?(tag[1..])
        else
          tags.includes?(tag)
        end
      end
    end

    def selects?(class_name : String, name : String, location : Runnable::Location, tags : Set(String)) : Bool
      selects_name?(class_name, name) &&
        selects_location?(location) &&
        selects_tags?(tags)
    end

    def to_s(io : IO) : Nil
      io << "Run options: --seed "
      seed.to_s(io)

      if verbose?
        io << " --verbose"
      end

      if chaos?
        io << " --chaos"
      end

      if fibers = @fibers
        io << " --parallel "
        fibers.to_s(io)
      end

      if pattern = @pattern
        io << " --name "
        pattern.inspect(io)
      end

      if fail_fast?
        io << " --fail-fast"
      end

      if line = @line
        io << " --line "
        line.to_s(io)
      end

      if location = @location
        io << " --location "
        location[0].to_s(io)
        io << ':'
        location[1].to_s(io)
      end

      @tags.each do |tag|
        io << " --tag "
        tag.to_s(io)
      end

      io << "\n"
    end
  end

  def self.options : Options
    @@options ||= Options.new
  end

  # A test's tags at collection time: it "x", tags: :slow, or an Array of
  # Symbols/Strings. Called from the generated per-test method, so the type is
  # known at each expansion.
  def self.normalize_tags(tags : Nil) : Set(String)
    Set(String).new
  end

  def self.normalize_tags(tags : Symbol | String) : Set(String)
    Set{tags.to_s}
  end

  def self.normalize_tags(tags : Enumerable) : Set(String)
    tags.map(&.to_s).to_set
  end

  def self.process_args(args : Enumerable(String)) : Nil
    OptionParser.parse(args) do |opts|
      opts.banner = "minitest options"

      opts.on("-h", "--help", "Display this help") do
        puts opts
        exit(0)
      end

      opts.on("-s SEED", "--seed SEED", "Sets random seed. Also via SEED environment variable.") do |seed|
        options.seed = seed.to_u32
      end

      opts.on("-v", "--verbose", "Show progress processing files.") do
        options.verbose = true
      end

      opts.on("-j PATH", "--junit PATH", "Generate junit report.") do |path|
        options.junit = path
      end

      opts.on("--color", "Enable ANSI colored output.") do
        options.color = true
      end

      opts.on("--no-color", "Disable ANSI colored output.") do
        options.color = false
      end

      opts.on("-p FIBERS", "--parallel FIBERS", "Parallelize runs.") do |fibers|
        options.fibers = fibers.to_i
      end

      opts.on("-c", "--chaos", "Shuffle all tests from all test suites.") do
        options.chaos = true
      end

      opts.on("-n PATTERN", "--name PATTERN", "Filter run on /pattern/ or string; matches the test name, its class name or Class#test_name.") do |pattern|
        options.pattern = pattern
      end

      opts.on("--fail-fast", "Stop the run after the first failed test.") do
        options.fail_fast = true
      end

      opts.on("-l LINE", "--line LINE", "Only run the test declared on LINE (within the it..end range).") do |line|
        unless number = line.to_i?
          STDERR.puts "minitest: --line expects a number, got #{line.inspect}"
          exit(2)
        end
        options.line = number
      end

      opts.on("--location FILE:LINE", "Only run the test declared at FILE:LINE.") do |spec|
        file, _, number = spec.rpartition(':')
        if file.empty? || (line = number.to_i?).nil?
          STDERR.puts "minitest: --location expects FILE:LINE, got #{spec.inspect}"
          exit(2)
        end
        options.location = {file, line, line}
      end

      opts.on("-t TAG", "--tag TAG", "Only run tests with TAG; prefix ~ to exclude. Repeatable.") do |tag|
        options.tags = tag
      end
    end
  end

  class_property reporter : AbstractReporter do
    CompositeReporter.new(options).tap do |reporter|
      reporter << SummaryReporter.new(options)
      reporter << ProgressReporter.new(options)
      if path = options.junit?
        reporter << JunitReporter.new(path, options)
      end
    end
  end

  def self.run(args = nil) : Bool
    process_args(args) if args
    puts options

    Colorize.enabled = options.color?

    # makes sure that reporter is initialized before spawning worker fibers:
    raise "BUG: no minitest reporter" unless self.reporter

    batches = build_batches
    start_hooks(batches)
    reset_stop

    channel = Channel(Array(Runnable::Data) | Runnable::Data).new(options.fibers * 4)
    completed = Channel(Nil).new

    {% if Fiber.has_constant?(:ExecutionContext) %}
      workers_count = Fiber::ExecutionContext.default_workers_count

        {% if Fiber::ExecutionContext.has_constant?(:Parallel) %}
          if (execution_context = Fiber::ExecutionContext.current).responds_to?(:resize)
            execution_context.resize(workers_count)
          else
            execution_context = Fiber::ExecutionContext::Parallel.new("MINITEST", workers_count)
          end
        {% else %}
          execution_context = Fiber::ExecutionContext::MultiThreaded.new("MINITEST", workers_count)
        {% end %}
    {% end %}

    options.fibers.times do |i|
      {% if Fiber.has_constant?(:ExecutionContext) %}
        execution_context.spawn(name: "minitest:worker-#{i}") do
          worker_loop(channel, completed)
        end
      {% else %}
        spawn(name: "minitest:worker-#{i}") do
          worker_loop(channel, completed)
        end
      {% end %}
    end
    reporter.start
    send_batches(batches, channel)
    options.fibers.times { completed.receive }

    finish_hooks
    reporter.report

    if stopped?
      STDERR.puts "\nStopped after the first failure (--fail-fast)."
    end

    reporter.passed?
  ensure
    after_run.each(&.call)
    reporter.passed?
  end

  # A fail-fast stop has to be visible to every worker fiber, and the workers may
  # run on different OS threads once the execution context is resized.
  @@stop_requested = Atomic(Bool).new(false)

  def self.stopped? : Bool
    @@stop_requested.get
  end

  def self.stop! : Nil
    @@stop_requested.set(true)
  end

  protected def self.reset_stop : Nil
    @@stop_requested.set(false)
  end

  # Lifecycle hook bookkeeping, keyed by class (not class name: two describes may
  # share a title). before_all runs with the first test this run executes for the
  # class, after_all with the last.
  @@hook_mutex = Mutex.new
  @@suite_pending = Hash(Test.class, Int32).new
  @@suite_started = Set(Test.class).new

  protected def self.start_hooks(batches : Array(Array(Runnable::Data))) : Nil
    pending = Hash(Test.class, Int32).new(0)
    batches.each do |batch|
      batch.each do |(suite, _name, _proc, _location)|
        pending[suite] = (pending[suite]? || 0) + 1
      end
    end

    @@hook_mutex.synchronize do
      @@suite_pending = pending
      @@suite_started = Set(Test.class).new
    end
  end

  def self.hook_first?(suite : Test.class) : Bool
    @@hook_mutex.synchronize { @@suite_started.add?(suite) }
  end

  def self.hook_last?(suite : Test.class) : Bool
    @@hook_mutex.synchronize do
      remaining = (@@suite_pending[suite]? || 0) - 1
      @@suite_pending[suite] = remaining
      remaining <= 0
    end
  end

  # A fail-fast stop leaves suites half-run; their after_all still has to happen
  # or a hook that started a server leaves it behind.
  def self.finish_hooks : Nil
    leftovers = @@hook_mutex.synchronize do
      pending = @@suite_pending.select { |_suite, remaining| remaining > 0 }
      pending.each_key { |suite| @@suite_pending[suite] = 0 }
      pending.keys
    end

    leftovers.each do |suite|
      suite.new(reporter).after_all
    rescue ex
      STDERR.puts "after_all for #{suite.name} failed: #{ex.message}"
    end
  end

  private def self.worker_loop(channel, completed) : Nil
    while value = channel.receive?
      case value
      in Array
        value.each do |test|
          next if stopped?
          suite, name, proc, _location = test
          suite.new(reporter).run_one(name, proc)
        end
      in Runnable::Data
        next if stopped?
        suite, name, proc, _location = value
        suite.new(reporter).run_one(name, proc)
      end
    end
    completed.send(nil)
  end

  # One batch per suite (chaos: one test per batch), shuffled with the seed before
  # any worker starts, so the lifecycle hooks know how many tests each suite runs.
  private def self.build_batches : Array(Array(Runnable::Data))
    random = Random::PCG32.new(options.seed.to_u64)

    if options.chaos?
      # collect & shuffle all tests for all suites:
      Runnable.runnables
        .reduce([] of Runnable::Data) { |tests, suite| tests + suite.collect_tests }
        .shuffle!(random)
        .map { |test| [test] }
    else
      # shuffle each suite, then shuffle tests for each suite:
      Runnable.runnables.shuffle!(random).flat_map do |suite|
        tests = suite.collect_tests
        next [] of Array(Runnable::Data) if tests.empty?
        [tests.shuffle!(random)]
      end
    end
  end

  private def self.send_batches(batches : Array(Array(Runnable::Data)), channel) : Nil
    batches.each do |batch|
      break if stopped?
      channel.send(batch)
    end
    channel.close
  end

  def self.after_run : Array(Proc(Nil))
    @@after_run ||= [] of ->
  end

  def self.after_run(&block : ->) : Nil
    after_run << block
  end

  def self.exit(status : Int32 = 1) : NoReturn
    after_run.each(&.call)
    ::exit status
  end
end
