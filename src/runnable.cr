require "set"

module Minitest
  class Runnable
    def self.runnables : Array(Runnable.class)
      {% begin %}
        [self, {{ @type.all_subclasses.join(", ").id }}]
      {% end %}
    end

    # The `it` declaration a test came from: the file, the line of the declaration
    # and the line of its closing `end`. Empty for tests declared as a plain
    # `def test_*`, which carry no declaration to point at.
    alias Location = {String, Int32, Int32}

    EMPTY_LOCATION = {"", 0, 0}

    alias Data = {Test.class, String, Proc(Test, Nil), Location}

    # Builds, at compile time, an Array with the test class, the test method name,
    # a proc to call that method and the declaration's location. Tests filtered out
    # by --name, --line, --location or --tag never enter the Array, so the summary
    # and the lifecycle hook counts describe what this run actually covers.
    def self.collect_tests : Array(Runnable::Data)
      tests = [] of Runnable::Data

      {% begin %}
        {% methods = @type.methods.map(&.name) %}
        {% class_names = @type.class.methods.map { |m| m.name.stringify } %}
        {% for name in methods.select(&.starts_with?("test_")) %}
          {% has_location = class_names.includes?("__minitest_src_" + name.stringify) %}
          {% has_tags = class_names.includes?("__minitest_tags_" + name.stringify) %}
          %location = {% if has_location %} {{ @type }}.__minitest_src_{{ name }} {% else %} EMPTY_LOCATION {% end %}
          %tags = {% if has_tags %} {{ @type }}.__minitest_tags_{{ name }} {% else %} Set(String).new {% end %}

          if Minitest.options.selects?({{ @type }}.name, {{ name.stringify }}, %location, %tags)
            %proc = ->(test : Test) {
              test.as({{ @type }}).{{ name }}
              nil
            }
            tests << { {{ @type }}, {{ name.stringify }}, %proc, %location }
          end
        {% end %}
      {% end %}

      tests
    end

    getter __reporter : AbstractReporter

    def initialize(@__reporter)
    end

    def should_run?(name : String) : Bool
      matches_pattern?(name)
    end

    def matches_pattern?(name : String) : Bool
      __reporter.options.selects_name?(self.class.name, name)
    end
  end
end
