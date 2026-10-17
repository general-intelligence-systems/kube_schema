# frozen_string_literal: true

# Bans a constant that does not match its file's path.
#
# @example
#   lib/mailers/welcome.rb          -> Mailers::Welcome          # YES
#   lib/mailers/welcome.rb          -> WelcomeMailer             # NO
#   lib/models/11_organization.rb   -> Models::Organization      # YES
#   lib/jobs/sync_tenant_claims.rb  -> Jobs::SyncTenantClaims    # YES
#   lib/jobs/sync_tenant_claims.rb  -> SyncTenantClaimsJob       # NO
module RuboCop
  module Cop
    module Local
      class ConstantMatchesPath < Base
        MSG = "`%<actual>s` does not match its path; this file should define " \
              "`%<expected>s` (or a constant nested inside it)."

        MSG_EMPTY = "This file defines no namespaced constant; it should define " \
                    "`%<expected>s`."

        # Directories that are a load path root, not a namespace segment.
        def roots = Array(cop_config.fetch("Roots", ["lib"]))

        def inflections = cop_config.fetch("Inflections", {})

        # Paths that legitimately define something else, such as monkey patches.
        def ignored = Array(cop_config.fetch("IgnorePaths", []))

        def on_new_investigation
          if processed_source.blank?
            nil
          else
            expected_namespace(processed_source.file_path).then do |expected|
              # A file outside a configured root, or an ignored path, has no namespace to be wrong about. Nor does one that defines no constant at all -- an empty file, or one that only runs code.
              unless expected.nil?
                report(top_level_constants(processed_source.ast), expected)
              end
            end
          end
        end

        private

          def report(defined, expected)
            defined.each do |name, node|
              unless matches?(name, expected)
                add_offense(node, message: format(MSG, actual: name, expected: expected))
              end
            end
          end

          # `Mailers::Welcome` is right for lib/mailers/welcome.rb, and so is `Mailers` alone (a file may open its own namespace to add to it).
          def matches?(actual, expected)
            actual == expected ||
              expected.start_with?("#{actual}::") ||
              actual.start_with?("#{expected}::")
          end

          def expected_namespace(path)
            parts = path.to_s.split(File::SEPARATOR)
            root  = parts.rindex { |part| roots.include?(part) }
            segments = root && parts[(root + 1)..]

            if segments.nil? || segments.empty? || ignored?(segments)
              nil
            else
              named = segments.dup
              named[-1] = named[-1].sub(/\.rb\z/, "")
              named.map { |segment| camelize(segment) }.join("::")
            end
          end

          def ignored?(segments)
            ignored.any? do |glob|
              File.fnmatch?(glob, segments.join("/"), File::FNM_PATHNAME)
            end
          end

          # `11_organization` -> `Organization`. The prefix orders loading; it is not part of the name.
          def camelize(segment)
            name = segment.sub(/\A\d+_/, "")

            if inflections.key?(name)
              inflections[name]
            else
              name.split("_").map { |word| inflections[word] || word.capitalize }.join
            end
          end

          # The constants a file opens at its top level, flattened through compact forms so `module A; class B` and `class A::B` both read as `A::B`.
          def top_level_constants(node, prefix = nil)
            if node.nil?
              []
            elsif node.begin_type?
              node.children.flat_map { |child| top_level_constants(child, prefix) }
            elsif node.module_type? || node.class_type?
              constants_in(node, prefix)
            else
              []
            end
          end

          def constants_in(node, prefix)
            name = qualified(node.children.first)

            if name.nil?
              []
            else
              if prefix
                full = "#{prefix}::#{name}"
              else
                full = name
              end

              body = node.children[node.class_type? ? 2 : 1]
              nested = top_level_constants(body, full)

              # Report the DEEPEST constant: `module Jobs; class Foo` is an offence about `Jobs::Foo`, not about `Jobs`.
              if nested.empty?
                [[full, node]]
              else
                nested
              end
            end
          end

          def qualified(const)
            if const&.const_type?
              namespace = const.namespace

              if namespace.nil? || namespace.cbase_type?
                const.short_name.to_s
              else
                inner = qualified(namespace)
                inner && "#{inner}::#{const.short_name}"
              end
            end
          end
      end
    end
  end
end
