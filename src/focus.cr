module Minitest
  class Runnable
    FOCUSES = Hash(String, Array(String)).new

    macro focus(definition)
      %focuses = FOCUSES[{{@type}}.name] ||= [] of String
      %focuses << {{definition.name.stringify}}
      {{definition}}
    end

    macro it(name = "anonymous", tags = nil, file = __FILE__, line = __LINE__, end_line = __END_LINE__, focus = false, &block)
      {% method = "test_" + name.strip.gsub(/[^\p{L}\p{N}]+/, "_") %}
      {% if focus %}focus{% end %} def {{ method.id }}
        ret = {{ yield }}
      end

      def self.__minitest_src_{{ method.id }} : Minitest::Runnable::Location
        { {{ file }}, {{ line }}, {{ end_line }} }
      end

      def self.__minitest_tags_{{ method.id }} : Set(String)
        Minitest.normalize_tags({{ tags }})
      end
    end
  end

  class Test < Runnable
    def should_run?(name) : Bool
      focused_test?(name) && super(name)
    end

    def focused_test?(name) : Bool
      if FOCUSES.empty?
        true
      else
        {% begin %}
          if focuses = FOCUSES[{{@type}}.name]?
            focuses.includes?(name)
          else
            false
          end
        {% end %}
      end
    end
  end
end
