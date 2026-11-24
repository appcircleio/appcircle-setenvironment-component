# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Run main.rb in a subprocess with the given ENV hash.
# Every input the step reads is unset by default; pass a value to set it.
# Open3.capture3 treats a nil value as "unset this variable in the child",
# which isolates the tests from the ambient environment.
def run_main(env = {})
  clean_env = {
    'AC_SETENV_KEYS'   => nil,
    'AC_SETENV_VALUE'  => nil,
    'AC_ENV_FILE_PATH' => nil
  }.merge(env)
  Open3.capture3(clean_env, "ruby #{MAIN_RB}")
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    ENV['_TEST_VAR'] = old
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_TEST_VAR'] = 'hello'
      expect(get_env_variable('_TEST_VAR')).to eq('hello')
    end

    it 'returns a whitespace-only value unchanged (not treated as empty)' do
      ENV['_TEST_VAR'] = '   '
      expect(get_env_variable('_TEST_VAR')).to eq('   ')
    end

    it 'returns a value containing spaces and "=" unchanged' do
      ENV['_TEST_VAR'] = 'a b=c'
      expect(get_env_variable('_TEST_VAR')).to eq('a b=c')
    end
  end

  context 'negative path' do
    it 'returns nil when the key is missing' do
      ENV.delete('_TEST_VAR')
      expect(get_env_variable('_TEST_VAR')).to be_nil
    end

    it 'returns nil when the value is an empty string' do
      ENV['_TEST_VAR'] = ''
      expect(get_env_variable('_TEST_VAR')).to be_nil
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#set_env_variables' do
  let(:tmpdir)   { Dir.mktmpdir('setenv_test') }
  let(:env_file) { File.join(tmpdir, 'env_file') }

  around do |example|
    old = ENV['AC_ENV_FILE_PATH']
    example.run
    ENV['AC_ENV_FILE_PATH'] = old
  end

  before { ENV['AC_ENV_FILE_PATH'] = env_file }
  after  { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'writes KEY=value for a single key' do
      set_env_variables(['MY_KEY'], 'my_value')
      expect(File.read(env_file)).to eq("MY_KEY=my_value\n")
    end

    it 'writes one line per key, all with the same value, in order' do
      set_env_variables(%w[KEY_A KEY_B KEY_C], 'shared')
      expect(File.read(env_file)).to eq("KEY_A=shared\nKEY_B=shared\nKEY_C=shared\n")
    end

    it 'writes KEY= when the value is an empty string' do
      set_env_variables(['EMPTY_KEY'], '')
      expect(File.read(env_file)).to eq("EMPTY_KEY=\n")
    end

    it 'writes values containing spaces and "=" verbatim' do
      set_env_variables(['URL'], 'https://x.io/?a=1&b=2 c')
      expect(File.read(env_file)).to eq("URL=https://x.io/?a=1&b=2 c\n")
    end

    it 'appends to an existing file instead of overwriting it' do
      File.write(env_file, "EXISTING=1\n")
      set_env_variables(['NEW_KEY'], '2')
      expect(File.read(env_file)).to eq("EXISTING=1\nNEW_KEY=2\n")
    end

    it 'creates the file when it does not exist yet' do
      expect(File.exist?(env_file)).to be(false)
      set_env_variables(['K'], 'v')
      expect(File.exist?(env_file)).to be(true)
    end

    it 'writes nothing (but creates the file) when the keys array is empty' do
      set_env_variables([], 'value')
      expect(File.read(env_file)).to eq('')
    end
  end

  context 'negative path' do
    it 'raises TypeError when AC_ENV_FILE_PATH is not set' do
      ENV.delete('AC_ENV_FILE_PATH')
      expect { set_env_variables(['K'], 'v') }.to raise_error(TypeError)
    end

    it 'raises Errno::ENOENT when AC_ENV_FILE_PATH is an empty string' do
      ENV['AC_ENV_FILE_PATH'] = ''
      expect { set_env_variables(['K'], 'v') }.to raise_error(Errno::ENOENT)
    end

    it 'raises Errno::ENOENT when the parent directory does not exist' do
      ENV['AC_ENV_FILE_PATH'] = File.join(tmpdir, 'missing_dir', 'env_file')
      expect { set_env_variables(['K'], 'v') }.to raise_error(Errno::ENOENT)
    end

    it 'raises NoMethodError when keys is nil' do
      expect { set_env_variables(nil, 'v') }.to raise_error(NoMethodError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb (subprocess)' do
  let(:tmpdir)   { Dir.mktmpdir('setenv_main_test') }
  let(:env_file) { File.join(tmpdir, 'env_file') }
  after { FileUtils.rm_rf(tmpdir) }

  context 'positive path' do
    it 'writes every space-separated key with the given value and exits 0' do
      _out, err, status = run_main(
        'AC_SETENV_KEYS'   => 'KEY_A KEY_B',
        'AC_SETENV_VALUE'  => 'hello',
        'AC_ENV_FILE_PATH' => env_file
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(env_file)).to eq("KEY_A=hello\nKEY_B=hello\n")
    end

    it 'ignores repeated and surrounding whitespace between keys' do
      _out, err, status = run_main(
        'AC_SETENV_KEYS'   => '  KEY_A    KEY_B  ',
        'AC_SETENV_VALUE'  => 'v',
        'AC_ENV_FILE_PATH' => env_file
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(env_file)).to eq("KEY_A=v\nKEY_B=v\n")
    end

    it 'writes KEY= when AC_SETENV_VALUE is missing (optional input)' do
      _out, err, status = run_main(
        'AC_SETENV_KEYS'   => 'ONLY_KEY',
        'AC_ENV_FILE_PATH' => env_file
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(env_file)).to eq("ONLY_KEY=\n")
    end

    it 'writes KEY= when AC_SETENV_VALUE is an empty string' do
      _out, err, status = run_main(
        'AC_SETENV_KEYS'   => 'ONLY_KEY',
        'AC_SETENV_VALUE'  => '',
        'AC_ENV_FILE_PATH' => env_file
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(env_file)).to eq("ONLY_KEY=\n")
    end

    it 'appends to an existing env file' do
      File.write(env_file, "PREVIOUS=1\n")
      _out, err, status = run_main(
        'AC_SETENV_KEYS'   => 'NEXT',
        'AC_SETENV_VALUE'  => '2',
        'AC_ENV_FILE_PATH' => env_file
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(env_file)).to eq("PREVIOUS=1\nNEXT=2\n")
    end

    it 'writes nothing when AC_SETENV_KEYS is whitespace only' do
      _out, err, status = run_main(
        'AC_SETENV_KEYS'   => '   ',
        'AC_SETENV_VALUE'  => 'v',
        'AC_ENV_FILE_PATH' => env_file
      )
      expect(status.exitstatus).to eq(0), err
      expect(File.read(env_file)).to eq('')
    end
  end

  context 'negative path – ENV validation' do
    shared_examples 'a failing validation' do |expected_pattern, env|
      it "exits non-zero and stderr matches #{expected_pattern.inspect}" do
        _out, err, status = run_main(env.call(env_file))
        expect(status.exitstatus).not_to eq(0)
        expect(err).to match(expected_pattern)
      end

      it 'does not write the env file' do
        run_main(env.call(env_file))
        expect(File.exist?(env_file)).to be(false)
      end
    end

    context 'AC_SETENV_KEYS is missing' do
      include_examples 'a failing validation',
                       /Missing Environment Variable Keys/,
                       ->(f) { { 'AC_SETENV_VALUE' => 'v', 'AC_ENV_FILE_PATH' => f } }
    end

    context 'AC_SETENV_KEYS is an empty string' do
      include_examples 'a failing validation',
                       /Missing Environment Variable Keys/,
                       ->(f) { { 'AC_SETENV_KEYS' => '', 'AC_SETENV_VALUE' => 'v', 'AC_ENV_FILE_PATH' => f } }
    end

    context 'AC_ENV_FILE_PATH is missing' do
      include_examples 'a failing validation',
                       /no implicit conversion of nil into String \(TypeError\)/,
                       ->(_f) { { 'AC_SETENV_KEYS' => 'K', 'AC_SETENV_VALUE' => 'v' } }
    end

    context 'AC_ENV_FILE_PATH is an empty string' do
      include_examples 'a failing validation',
                       /No such file or directory/,
                       ->(_f) { { 'AC_SETENV_KEYS' => 'K', 'AC_SETENV_VALUE' => 'v', 'AC_ENV_FILE_PATH' => '' } }
    end

    context 'AC_ENV_FILE_PATH points to a non-existent directory' do
      it 'exits non-zero with a No such file or directory error' do
        bad_path = File.join(tmpdir, 'missing_dir', 'env_file')
        _out, err, status = run_main(
          'AC_SETENV_KEYS'   => 'K',
          'AC_SETENV_VALUE'  => 'v',
          'AC_ENV_FILE_PATH' => bad_path
        )
        expect(status.exitstatus).not_to eq(0)
        expect(err).to match(/No such file or directory/)
        expect(File.exist?(bad_path)).to be(false)
      end
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
