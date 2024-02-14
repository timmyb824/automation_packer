if [[ $TERM_PROGRAM != "WarpTerminal" ]]; then
    source <($HOME/.local/bin/starship init zsh --print-full-init) #pkgx
    export STARSHIP_CONFIG="$HOME/.config/starship/starship.toml"
fi

autoload -Uz compinit && compinit

source <(pkgx --shellcode)  #docs.pkgx.sh/shellcode