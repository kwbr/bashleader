# Loaded in an isolated subshell by leadr_init.
# Format: leadr_map KEY DESCRIPTION FLAGS COMMAND

leadr_map gs 'Git status' REPLACE+EXEC 'git status'
leadr_map gc 'Start a Git commit' REPLACE 'git commit -m "#CURSOR"'
leadr_map id 'Insert the current date' INSERT+EVAL 'date +%Y%m%d'
leadr_map ps 'Prepend sudo' PREPEND 'sudo '
leadr_map pl 'Append a less pager' APPEND ' | less'
leadr_map sq 'Surround with single quotes' SURROUND "'#COMMAND'"
