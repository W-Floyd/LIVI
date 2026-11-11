# Sourced. Exports KEY=value lines from godot-shell/.env (gitignored: this machine's paths, see
# .env.example) that the environment does not already set. Values are taken literally.
_env=${LIVI_ENV:-$(git -C "$(dirname -- "$0")" rev-parse --show-toplevel 2>/dev/null)/godot-shell/.env}
if [ -f "$_env" ]; then
	while IFS= read -r _l || [ -n "$_l" ]; do
		case $_l in '' | '#'*) continue ;; esac
		_k=${_l%%=*}
		case $_k in '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;; esac
		eval "[ -n \"\${$_k+x}\" ]" || eval "export $_k=\"\${_l#*=}\""
	done <"$_env"
fi
unset _env _l _k
