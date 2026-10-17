# frozen_string_literal: true

# Bans a call with more than `MaxArguments` arguments.
#
# @example
#   walk(rest, current_dir, controller_segments, dynamic_pairs + [[param_name, segment]], last_dir_name)
#
# @example Each argument on its own line
#   walk(                                                           # YES
#     rest,
#     current_dir,
#     controller_segments,
#     dynamic_pairs + [[param_name, segment]],
#     last_dir_name,
#   )
module RuboCop
  module Cop
    module Local
      class MultilineMethodArguments < Base
        extend AutoCorrector

        MSG = "Call takes %<count>d arguments; put each one on its own line."

        def on_send(node)
          if too_many_on_one_line?(node)
            add_offense(node, message: format(MSG, count: node.arguments.count)) do |corrector|
              break_arguments(corrector, node)
            end
          end
        end

        alias on_csend on_send
        alias on_super on_send

        private

          def too_many_on_one_line?(node)
            node.parenthesized? &&
              node.arguments.count > max_arguments &&
              !every_argument_on_its_own_line?(node)
          end

          # The first argument must clear the line that opened the call, and no two arguments may share a line.
          def every_argument_on_its_own_line?(node)
            lines = node.arguments.map { |argument| argument.source_range.first_line }

            lines.first > node.loc.begin.line && lines == lines.uniq
          end

          def break_arguments(corrector, node)
            if safe_to_break?(node)
              corrector.insert_after(node.loc.begin, "\n")

              node.arguments.each_cons(2) do |left, right|
                corrector.replace(between(left, right), ",\n")
              end

              corrector.insert_before(node.loc.end, "\n")
            end
          end

          # A heredoc's body sits below its line, and comments between arguments would be overwritten; both are left alone.
          def safe_to_break?(node)
            node.arguments.none? { |argument| contains_heredoc?(argument) } &&
              node.arguments.each_cons(2).none? do |left, right|
                between(left, right).source.include?("#")
              end
          end

          def contains_heredoc?(node)
            node.each_node(:str, :dstr, :xstr).any?(&:heredoc?)
          end

          # The comma-and-whitespace run separating two arguments.
          def between(left, right)
            Parser::Source::Range.new(
              processed_source.buffer,
              left.source_range.end_pos,
              right.source_range.begin_pos,
            )
          end

          def max_arguments
            cop_config.fetch("MaxArguments", 3)
          end
      end
    end
  end
end
