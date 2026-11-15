require "./expectations"

module Minitest
  class Spec < Test
    macro let(name, &block)
      {% if name.is_a?(TypeDeclaration) %}
        {% if name.value && block %}
          {% raise "A let declaration MUST have a default value OR an initializer block but NOT both" %}
        {% end %}

        @{{name.var}} : {{name.type}} | Nil

        def {{name.var}} : {{name.type}}
          @{{name.var}} ||= {% if block %} {{yield}} {% else %} {{name.value}} {% end %}
        end
      {% else %}
        def {{name.id}}
          @{{name.id}} ||= {{yield}}
        end
      {% end %}
    end

    macro before(&block)
      def setup
        super()
        {{ yield }}
      end
    end

    macro after(&block)
      def teardown
        {{ yield }}
        super()
      end
    end

    # Runs once for the whole describe, with its first test (not before every test
    # like before/setup). State shared with the tests must be class level.
    macro before_all(&block)
      def before_all
        {{ yield }}
      end
    end

    # Runs once for the whole describe, with its last test.
    macro after_all(&block)
      def after_all
        {{ yield }}
      end
    end

    macro describe(name, &block)
      {%
        class_name = name.id.stringify
          .split("::")
          .map(&.gsub(/[^\p{L}\p{N}]+/, "_").gsub(/^_|_$/, "").camelcase)
          .join("::")
      %}
      class {{ class_name.id }}Spec < {{ @type }}
        def self.name : String
          "#{ {{ @type }}.name }::{{ name.id }}"
        end

        {{ yield }}
      end
    end

    # The declaration's file, line and closing `end` are recorded with the test so
    # --line and --location can select it; tags are matched by --tag at collection
    # time. Tests declared as plain `def test_*` have neither.
    macro it(name = "anonymous", tags = nil, file = __FILE__, line = __LINE__, end_line = __END_LINE__, &block)
      {% method = "test_" + name.strip.gsub(/[^\p{L}\p{N}]+/, "_") %}
      def {{ method.id }}
        {{ yield }}
      end

      def self.__minitest_src_{{ method.id }} : Minitest::Runnable::Location
        { {{ file }}, {{ line }}, {{ end_line }} }
      end

      def self.__minitest_tags_{{ method.id }} : Set(String)
        Minitest.normalize_tags({{ tags }})
      end
    end

    def expect(value) : Expectation
      Expectation.new(value)
    end
  end
end

# TODO: allow to inherit from specific classes (configurable with matcher)
macro describe(name, &block)
  {%
    class_name = name.id.stringify
      .split("::")
      .map(&.gsub(/[^\p{L}\p{N}]+/, "_").gsub(/^_|_$/, "").camelcase)
      .join("::")
  %}
  class {{ class_name.id }}Spec < Minitest::Spec
    def self.name : String
      {{ name.id.stringify }}
    end

    {{ yield }}
  end
end
