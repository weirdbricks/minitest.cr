require "../src/autorun"

class FeaturesTest < Minitest::Test
  HEX              = Random::Secure.hex(3)
  BINARY_PATH      = File.expand_path("features_#{HEX}_test", __DIR__)
  SOURCE_PATH      = BINARY_PATH + ".cr"
  FAIL_BINARY_PATH = File.expand_path("features_fail_#{HEX}_test", __DIR__)
  FAIL_SOURCE_PATH = FAIL_BINARY_PATH + ".cr"

  FIXTURE = [
    %(require "../src/autorun"),
    %(),
    %(def mark(name)),
    %(  path = ENV["MARKER"]?),
    %(  return unless path),
    %(  File.open(path, "a") { |file| file.puts name }),
    %(end),
    %(),
    %(describe "Hook suite" do),
    %(  before_all { mark("before_all") }),
    %(  after_all { mark("after_all") }),
    %(),
    %(  it "hook one" { mark("test_hook_one") }),
    %(  it "hook two" { mark("test_hook_two") }),
    %(end),
    %(),
    %(describe "Tag suite" do),
    %(  it "plain" { mark("test_plain") }),
    %(  it "slow one", tags: :slow { mark("test_slow_one") }),
    %(  it "slow infra", tags: [:slow, :infra] { mark("test_slow_infra") }),
    %(end),
    %(),
    %(describe "Filter suite" do),
    %(  it "first" { mark("test_first") }),
    %(  it "second" { mark("test_second") }),
    %(end),
    %(),
  ]

  FAIL_FIXTURE = [
    %(require "../src/autorun"),
    %(),
    %(def mark(name)),
    %(  path = ENV["MARKER"]?),
    %(  return unless path),
    %(  File.open(path, "a") { |file| file.puts name }),
    %(end),
    %(),
    %(describe "Fail fast suite" do),
    %(  before_all { mark("before_all") }),
    %(  after_all { mark("after_all") }),
    %(),
    %(  it "a" { mark("test_a"); assert false }),
    %(  it "b" { mark("test_b"); assert false }),
    %(  it "c" { mark("test_c"); assert false }),
    %(  it "d" { mark("test_d"); assert false }),
    %(end),
    %(),
  ]

  # 1-based line of the first fixture line containing +snippet+.
  def self.line_of(snippet : String) : Int32
    FIXTURE.index { |line| line.includes?(snippet) }.not_nil! + 1
  end

  {% if flag?(:interpreted) %}
    def setup
      skip "Process doesn't work in the Crystal interpreter (the VM waits forever for SIGCHLD)"
    end
  {% else %}
    begin
      File.write(SOURCE_PATH, FIXTURE.join('\n'))
      File.write(FAIL_SOURCE_PATH, FAIL_FIXTURE.join('\n'))

      crystal = ENV.fetch("CRYSTAL", "crystal")
      {SOURCE_PATH, FAIL_SOURCE_PATH}.each do |source|
        binary = source.rchop(".cr")
        unless Process.run(crystal, ["build", source, "-o", binary]).success?
          STDERR.puts "Failed to build features test"
          Minitest.exit(1)
        end
      end
    end

    Minitest.after_run do
      [BINARY_PATH, SOURCE_PATH, FAIL_BINARY_PATH, FAIL_SOURCE_PATH].each do |path|
        File.delete(path) if File.exists?(path)
      end
    end
  {% end %}

  def test_before_all_and_after_all_run_once
    marks = run_marks(FIXTURE, BINARY_PATH)
    assert_equal 1, marks.count("before_all")
    assert_equal 1, marks.count("after_all")
    assert_equal 1, marks.count("test_hook_one")
    assert_equal 1, marks.count("test_hook_two")
    before = marks.index("before_all").not_nil!
    after = marks.index("after_all").not_nil!
    assert before < marks.index("test_hook_one").not_nil!
    assert before < marks.index("test_hook_two").not_nil!
    assert after > marks.index("test_hook_one").not_nil!
    assert after > marks.index("test_hook_two").not_nil!
  end

  def test_tags_include
    stdout, _stderr, rs = execute(["--tag", "slow", "--verbose"])
    assert rs.success?
    assert_match(/Tag suite#test_slow_one = [\d.]+ s = \./, stdout)
    assert_match(/Tag suite#test_slow_infra = [\d.]+ s = \./, stdout)
    refute_match(/Tag suite#test_plain =/, stdout)
    assert_match "2 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_tags_exclude
    stdout, _stderr, rs = execute(["--tag", "~slow", "--verbose"])
    assert rs.success?
    refute_match(/#test_slow_/, stdout)
    assert_match "5 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_tags_include_and_exclude
    stdout, _stderr, rs = execute(["--tag", "slow", "--tag", "~infra", "--verbose"])
    assert rs.success?
    assert_match(/Tag suite#test_slow_one = [\d.]+ s = \./, stdout)
    refute_match(/Tag suite#test_slow_infra =/, stdout)
    assert_match "1 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_name_matches_the_class_name
    stdout, _stderr, rs = execute(["--name", "/Tag suite/", "--verbose"])
    assert rs.success?
    assert_match(/Tag suite#test_plain =/, stdout)
    assert_match(/Tag suite#test_slow_one =/, stdout)
    assert_match(/Tag suite#test_slow_infra =/, stdout)
    refute_match(/Hook suite#/, stdout)
    assert_match "3 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_name_matches_class_and_test_name
    stdout, _stderr, rs = execute(["--name", "/Hook suite#test_hook_two/", "--verbose"])
    assert rs.success?
    assert_match(/Hook suite#test_hook_two =/, stdout)
    refute_match(/Hook suite#test_hook_one =/, stdout)
    assert_match "1 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_line_selects_the_test_declared_there
    stdout, _stderr, rs = execute(["--line", self.class.line_of(%(it "hook two")).to_s, "--verbose"])
    assert rs.success?
    assert_match(/Hook suite#test_hook_two =/, stdout)
    refute_match(/Hook suite#test_hook_one =/, stdout)
    assert_match "1 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_location_selects_by_file_and_line
    line = self.class.line_of(%(it "second"))
    stdout, _stderr, rs = execute(["--location", "#{File.basename(SOURCE_PATH)}:#{line}", "--verbose"])
    assert rs.success?
    assert_match(/Filter suite#test_second =/, stdout)
    refute_match(/Filter suite#test_first =/, stdout)
    assert_match "1 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_line_covering_no_test_runs_nothing
    stdout, _stderr, rs = execute(["--line", "2"])
    assert rs.success?
    assert_match "0 tests, 0 failures, 0 errors, 0 skips", stdout
  end

  def test_fail_fast_stops_after_the_first_failure
    path = File.tempname("minitest-features", ".txt")
    File.write(path, "")
    stdout, _stderr, rs = execute(["--fail-fast"], binary: FAIL_BINARY_PATH, env: {"MARKER" => path})
    refute rs.success?, "the failing test must fail the run"
    marks = File.read(path).lines
    assert_equal 1, marks.count { |mark| mark.starts_with?("test_") }, "fail-fast ran more than one test"
    assert_equal 1, marks.count("after_all"), "after_all must still run for a suite fail-fast cut short"
    assert_match "1 tests, 1 failures", stdout
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  def test_without_fail_fast_every_test_runs
    path = File.tempname("minitest-features", ".txt")
    File.write(path, "")
    stdout, _stderr, rs = execute([] of String, binary: FAIL_BINARY_PATH, env: {"MARKER" => path})
    refute rs.success?, "the failing tests must fail the run"
    marks = File.read(path).lines
    assert_equal 4, marks.count { |mark| mark.starts_with?("test_") }
    assert_match "4 tests, 4 failures", stdout
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  private def run_marks(_fixture : Array(String), binary : String, args : Array(String) = [] of String, pass : Bool? = nil) : Array(String)
    path = File.tempname("minitest-features", ".txt")
    File.write(path, "")
    stdout, stderr, rs = execute(args, binary: binary, env: {"MARKER" => path})
    if pass == true
      assert rs.success?, "expected the run to pass, but it failed:\n#{stderr}"
    elsif pass == false
      refute rs.success?, "expected the run to fail, but it passed:\n#{stdout}"
    end
    File.read(path).lines
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  private def execute(argv : Array(String), binary : String = BINARY_PATH, env : Hash(String, String)? = nil) : {String, String, Process::Status}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    rs = Process.run(binary, argv, env: env, output: stdout, error: stderr)

    {stdout.rewind.to_s, stderr.rewind.to_s, rs}
  end
end
