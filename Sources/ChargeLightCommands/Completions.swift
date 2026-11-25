import ChargeLight
import Foundation

/// Shell completion scripts for `chargelight completions <shell>`. They are
/// generated from ``CLI/commands``, so they list every command and option;
/// state, pattern and preset names are the built-in ones.
enum Completions {
    /// What an option's value is, for completion.
    enum Value {
        case none, duration, text, number, colour, show, hookAction
    }

    /// Every option's description and value kind.
    static let options: [String: (summary: String, value: Value)] = [
        "--for": ("show it for this long", .duration),
        "--ttl": ("claim lifetime", .duration),
        "--keep": ("how long to show the result, 0 releases", .duration),
        "--label": ("short description", .text),
        "--id": ("claim id", .text),
        "--times": ("how many times (1-100)", .number),
        "--priority": ("higher wins", .number),
        "--unit": ("Morse unit in ms (50-1000)", .number),
        "--count": ("stop after this many lines", .number),
        "--color": ("colour of the Morse code", .colour),
        "--working": ("what to show while it runs", .show),
        "--ok": ("what to show after success", .show),
        "--fail": ("what to show after failure", .show),
        "--as": ("force an action", .hookAction),
        "--wait": ("return once it is over", .none),
    ]

    static let shells = ["zsh", "bash", "fish"]

    static var states: [String] { LEDState.allCases.map(\.rawValue) }
    static var patterns: [String] { Pattern.builtIn.keys.sorted() }
    static var presets: [String] { Configuration.builtInPresets.keys.sorted() }
    /// What `set` and the shorthand take.
    static var names: [String] { states + patterns }

    static func script(for shell: String) -> String? {
        switch shell {
        case "zsh": return zsh()
        case "bash": return bash()
        case "fish": return fish()
        default: return nil
        }
    }

    // MARK: - zsh

    static func zsh() -> String {
        func choices(_ value: Value) -> String {
            switch value {
            case .none: return ""
            case .duration: return ":duration (90s, 10m, 2h):"
            case .text: return ":text:"
            case .number: return ":number:"
            case .colour: return ":colour:(amber green)"
            case .show: return ":state, pattern or preset:(\((names + presets).joined(separator: " ")))"
            case .hookAction: return ":action:(\((presets + ["release"]).joined(separator: " ")))"
            }
        }
        func optionSpec(_ name: String) -> String {
            let (summary, value) = options[name] ?? ("", .text)
            return value == .none ? "'\(name)[\(summary)]'" : "'\(name)=[\(summary)]\(choices(value))'"
        }
        let positionals: [String: [String]] = [
            "set": ["'1:state or pattern:(\(names.joined(separator: " ")))'"],
            "flash": ["'1:colour or pattern:(green amber \(patterns.joined(separator: " ")))'"],
            "morse": ["'*:text:'"],
            "claim": ["'1:claim id:'", "'2:state, pattern or preset:(\((names + presets).joined(separator: " ")))'"],
            "release": ["'1:claim id:'"],
            "completions": ["'1:shell:(\(shells.joined(separator: " ")))'"],
        ]
        let commandList = CLI.commands.map { "    '\($0.name):\($0.summary)'" }.joined(separator: "\n")
        let cases = CLI.commands.map { command -> String in
            let specs = ["$global"] + command.options.map(optionSpec) + (positionals[command.name] ?? [])
            return "    (\(command.name)) _arguments -s \(specs.joined(separator: " ")) ;;"
        }.joined(separator: "\n")
        return """
            #compdef chargelight
            # zsh completion for chargelight \(ChargeLight.version)
            # Install: chargelight completions zsh > "${fpath[1]}/_chargelight"

            _chargelight() {
              local -a commands names global
              commands=(
            \(commandList)
              )
              names=(\(names.joined(separator: " ")))
              global=(
                '--json[print JSON]'
                '(-q --quiet)'{-q,--quiet}'[print nothing on success]'
                '(-h --help)'{-h,--help}'[show help]'
              )

              if (( CURRENT == 2 )); then
                _describe -t commands 'chargelight command' commands
                _describe -t names 'state or pattern (shorthand for set)' names
                return
              fi

              local cmd=$words[2]
              # chargelight run [options] -- <command> [args...]
              if [[ $cmd == run ]]; then
                local dashdash=${words[(i)--]}
                if (( dashdash < CURRENT )); then
                  shift $dashdash words
                  (( CURRENT -= dashdash ))
                  _normal
                  return
                fi
              fi

              shift words
              (( CURRENT-- ))
              case $cmd in
            \(cases)
                (*) _arguments -s $global '--for=[show it for this long]:duration (90s, 10m, 2h):' ;;
              esac
            }

            _chargelight "$@"

            """
    }

    // MARK: - bash

    static func bash() -> String {
        let valueOptions = options.filter { $0.value.value != .none }.keys.sorted()
        let optionCases = CLI.commands.filter { !$0.options.isEmpty }
            .map { "        \($0.name)) options=\"\($0.options.joined(separator: " "))\" ;;" }
            .joined(separator: "\n")
        let freeform = valueOptions.filter { options[$0]?.value != .colour && options[$0]?.value != .show && options[$0]?.value != .hookAction }
        return """
            # bash completion for chargelight \(ChargeLight.version)
            # Install: chargelight completions bash > "$(brew --prefix)/etc/bash_completion.d/chargelight"

            _chargelight() {
                local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
                local commands="\(CLI.commands.map(\.name).joined(separator: " "))"
                local names="\(names.joined(separator: " "))"
                local patterns="\(patterns.joined(separator: " "))"
                local presets="\(presets.joined(separator: " "))"
                local value_options=" \(valueOptions.joined(separator: " ")) "
                local global="--json --quiet --help"
                local i word cmd="" npos=0 skip=0

                for ((i = 1; i < COMP_CWORD; i++)); do
                    word=${COMP_WORDS[i]}
                    if ((skip)); then
                        skip=0
                        continue
                    fi
                    # chargelight run [options] -- <command> [args...]
                    if [[ $cmd == run && $word == -- ]]; then
                        if ((i == COMP_CWORD - 1)); then
                            COMPREPLY=($(compgen -c -- "$cur"))
                        else
                            COMPREPLY=($(compgen -f -- "$cur"))
                        fi
                        return 0
                    fi
                    case $word in
                        --*=*) ;;
                        -*) [[ $value_options == *" $word "* ]] && skip=1 ;;
                        *)
                            if [[ -z $cmd ]]; then
                                cmd=$word
                            else
                                npos=$((npos + 1))
                            fi
                            ;;
                    esac
                done

                case $prev in
                    --color) COMPREPLY=($(compgen -W "amber green" -- "$cur")); return 0 ;;
                    --working|--ok|--fail) COMPREPLY=($(compgen -W "$names $presets" -- "$cur")); return 0 ;;
                    --as) COMPREPLY=($(compgen -W "$presets release" -- "$cur")); return 0 ;;
                    \(freeform.joined(separator: "|"))) return 0 ;;
                esac

                if [[ -z $cmd ]]; then
                    COMPREPLY=($(compgen -W "$commands $names $global --version" -- "$cur"))
                    return 0
                fi

                local options=""
                case $cmd in
            \(optionCases)
                esac
                if [[ $cur == -* ]]; then
                    COMPREPLY=($(compgen -W "$options $global" -- "$cur"))
                    return 0
                fi

                case $cmd in
                    set) ((npos == 0)) && COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
                    flash) ((npos == 0)) && COMPREPLY=($(compgen -W "green amber $patterns" -- "$cur")) ;;
                    claim) ((npos == 1)) && COMPREPLY=($(compgen -W "$names $presets" -- "$cur")) ;;
                    completions) ((npos == 0)) && COMPREPLY=($(compgen -W "\(shells.joined(separator: " "))" -- "$cur")) ;;
                esac
                return 0
            }

            complete -F _chargelight chargelight

            """
    }

    // MARK: - fish

    static func fish() -> String {
        var lines = [
            "# fish completion for chargelight \(ChargeLight.version)",
            "# Install: chargelight completions fish > ~/.config/fish/completions/chargelight.fish",
            "",
            "complete -c chargelight -f",
            "set -l commands \(CLI.commands.map(\.name).joined(separator: " "))",
            "",
            "# Commands, and the shorthand chargelight <state|pattern>",
        ]
        for command in CLI.commands {
            lines.append(
                "complete -c chargelight -n \"not __fish_seen_subcommand_from $commands\" -a \(command.name) -d '\(command.summary)'")
        }
        lines.append(
            "complete -c chargelight -n \"not __fish_seen_subcommand_from $commands\" -a '\(names.joined(separator: " "))' -d 'state or pattern'")
        lines += [
            "",
            "# Global options",
            "complete -c chargelight -l json -d 'print JSON'",
            "complete -c chargelight -s q -l quiet -d 'print nothing on success'",
            "complete -c chargelight -s h -l help -d 'show help'",
            "complete -c chargelight -l version -d 'print the version'",
            "",
            "# Arguments",
            "complete -c chargelight -n '__fish_seen_subcommand_from set' -a '\(names.joined(separator: " "))'",
            "complete -c chargelight -n '__fish_seen_subcommand_from flash' -a 'green amber \(patterns.joined(separator: " "))'",
            "complete -c chargelight -n '__fish_seen_subcommand_from claim' -a '\((names + presets).joined(separator: " "))'",
            "complete -c chargelight -n '__fish_seen_subcommand_from completions' -a '\(shells.joined(separator: " "))'",
            "complete -c chargelight -n '__fish_seen_subcommand_from run' -F",
            "",
            "# Command options",
        ]
        for command in CLI.commands {
            for option in command.options {
                let (summary, value) = options[option] ?? ("", .text)
                var line = "complete -c chargelight -n '__fish_seen_subcommand_from \(command.name)' -l \(option.dropFirst(2))"
                switch value {
                case .none: break
                case .colour: line += " -x -a 'amber green'"
                case .show: line += " -x -a '\((names + presets).joined(separator: " "))'"
                case .hookAction: line += " -x -a '\((presets + ["release"]).joined(separator: " "))'"
                case .duration, .text, .number: line += " -x"
                }
                lines.append(line + " -d '\(summary)'")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension CLI {
    func completionsCommand(shell: String) throws -> CommandOutput {
        guard let script = Completions.script(for: shell) else {
            throw ChargeLightError.invalidArgument(
                "unknown shell \"\(shell)\" (expected one of: \(Completions.shells.joined(separator: ", ")))")
        }
        return CommandOutput(fields: ["shell": .string(shell), "script": .string(script)], text: script)
    }
}
