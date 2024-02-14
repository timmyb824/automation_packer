#!/bin/bash

# Make sure we exit if there is a failure at any step
set -e

#######################
#  Global Functions  #
#######################

# Function to check if a given line is in a file
line_in_file() {
    local line="$1"
    local file="$2"
    grep -Fq -- "$line" "$file"
}

# Function to echo with color and newlines for visibility
echo_with_color() {
    local color_code="$1"
    local message="$2"
    echo -e "\n\033[${color_code}m$message\033[0m\n"
}

# Function to output an error message and exit
exit_with_error() {
    echo_with_color "31" "Error: $1" >&2
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Function to determine the current operating system
get_os() {
    case "$(uname -s)" in
    Linux*) echo "Linux" ;;
    *) echo "Unknown" ;;
    esac
}

# Function to add a directory to PATH if it's not already there
add_to_path() {
    if ! echo "$PATH" | grep -q "$1"; then
        echo_with_color "32" "Adding $1 to PATH for the current session..."
        export PATH="$1:$PATH"
    fi
}

# Function to add a directory to PATH if it's not already there and if it's an exact match
add_to_path_exact_match() {
    if [[ ":$PATH:" != *":$1:"* ]]; then
        echo_with_color "32" "Adding $1 to PATH for the current session..."
        export PATH="$1:$PATH"
    else
        echo_with_color "34" "$1 is already in PATH"
    fi
}

attempt_fix_command() {
    local cmd="$1"
    local cmd_path="$2"
    if ! check_command "$cmd"; then
        add_to_path "$cmd_path"
        if ! check_command "$cmd"; then
            exit_with_error "$cmd is still not available after updating the PATH"
        fi
    fi
}

# General function to check if a command is available
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        echo_with_color "31" "$cmd could not be found"
        return 1
    else
        echo_with_color "32" "$cmd is available"
        return 0
    fi
}

#######################
#  Global Envars      #
#######################

OS=$(get_os)
TAILSCALE_AUTH_KEY="INSERT_YOUR_TAILSCALE_AUTH_KEY_HERE"
NODE_VERSION="v21.0.0"
TF_VERSION="latest"
PYTHON_VERSION="3.11.0"
RUBY_VERSION="3.2.1"

#######################
#      Check OS       #
#######################

if [ "$OS" != "Linux" ]; then
    exit_with_error "This script is only intended to run on Linux."
fi

#######################
#     Install Zsh     #
#######################

# Check for Zsh and install if not present
if ! command_exists zsh; then
    echo_with_color "33" "Zsh not found. Installing Zsh..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zsh
else
    echo_with_color "32" "Zsh is already installed."
fi

# Check if the default shell is already Zsh
CURRENT_SHELL=$(getent passwd "$(whoami)" | cut -d: -f7)
if [ "$CURRENT_SHELL" != "$(command -v zsh)" ]; then
    echo_with_color "32" "Changing the default shell to Zsh..."
    sudo chsh -s "$(which zsh)" "$(whoami)"
else
    echo_with_color "34" "Zsh is already the default shell."
fi

# Check if we're already running Zsh to prevent a loop
if [ -n "$ZSH_VERSION" ]; then
    echo_with_color "34" "Already running Zsh, no need to switch."
else
    # Executing the Zsh shell
    # The exec command replaces the current shell with zsh.
    # The "$0" refers to the script itself, and "$@" passes all the original arguments passed to the script.
    if [ -x "$(command -v zsh)" ]; then
        echo_with_color "34" "Switching to Zsh for the remainder of the script..."
        exec zsh -l "$0" "$@"
    fi
fi

echo_with_color "32" "Zsh installation complete."

#######################
#  Install tailscale  #
#######################

install_tailscale() {
    # Check if curl is installed, if not, install it
    if ! command_exists curl; then
        echo_with_color "33" "curl is not installed. Installing curl..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install curl -y || exit_with_error "Failed to install curl. Exiting."
    fi

    echo_with_color "32" "Installing Tailscale..."
    RELEASE=$(lsb_release -cs)
    # Add the Tailscale repository signing key and repository
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${RELEASE}.noarmor.gpg" | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${RELEASE}.tailscale-keyring.list" | sudo tee /etc/apt/sources.list.d/tailscale.list

    # Update the package list and install Tailscale
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y || exit_with_error "Failed to update package list. Exiting."

    sudo DEBIAN_FRONTEND=noninteractive apt-get install tailscale -y || exit_with_error "Failed to install Tailscale. Exiting."

    # Start Tailscale and authenticate
    sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --operator="$USER"
}

if command_exists tailscale; then
    status=$(sudo tailscale status)
    if [[ "$status" == *"Tailscale is stopped."* ]]; then
        echo_with_color "34" "Tailscale is installed but stopped. Starting Tailscale..."
        sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --operator="$USER"
    else
        echo_with_color "32" "Tailscale is running."
    fi
else
    install_tailscale
fi

echo_with_color "32" "Tailscale installation complete."

#######################
#    Install pkgx     #
#######################

# Check if pkgx is installed
install_pkgx() {
    # Check if curl is installed, if not, install it
    if ! command_exists curl; then
        echo_with_color "33" "curl is not installed. Installing curl..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install curl -y || exit_with_error "Failed to install curl. Exiting."
    fi

    echo_with_color "32" "Installing pkgx..."
    curl -Ssf https://pkgx.sh | sh || exit_with_error "Failed to install pkgx. Exiting."
}

# Check if pkgx is installed, if not then install it
if ! command_exists pkgx; then
    echo_with_color "31" "pkgx could not be found"
    install_pkgx
fi

# Verify if pkgx was successfully installed
command_exists pkgx || exit_with_error "pkgx installation failed."

# List of packages to install
packages=(
    "aiac"
    "asciinema"
    "atlasgo.io"
    "awk"
    "aws"
    "aws-vault"
    "aws-whoami"
    "awslogs"
    "bat"
    "bore.pub"
    "broot"
    "btm"
    "chezmoi.io"
    "click"
    "cloc"
    "cog"
    "commit"
    "config_data"
    "csview"
    "cw"
    "dialog"
    "dblab"
    "direnv"
    "diskus"
    "diskonaut"
    "dive"
    "docker-clean"
    "dog"
    "dua"
    "duf"
    "enc"
    "exa"
    "eza"
    "fblog"
    "fd"
    "fend"
    "find"
    "fish"
    "fish_indent"
    "fish_key_reader"
    "fnm"
    "fselect"
    "fx"
    "fzf"
    "gh"
    "ghq"
    "git"
    "git-cvsserver"
    "git-gone"
    "git-quick-stats"
    "git-receive-pack"
    "git-shell"
    "git-town"
    "git-trim"
    "git-upload-archive"
    "git-upload-pack"
    "gitleaks"
    "gitopolis"
    "gitui"
    "gitweb"
    "glow"
    "go"
    "gofmt"
    "gum"
    "helm"
    "htop"
    "http"
    "httpie"
    "https"
    "hurl"
    "hurlfmt"
    "jetp"
    "jq"
    "just"
    "k6"
    "k9s"
    "killport"
    "kind"
    "kubectl"
    "kubectl-krew"
    "lazygit"
    "lego"
    "locate"
    "lsd"
    "mackup"
    "melt"
    "micro"
    "min.io/mc"
    "mongosh"
    "mprocs"
    "ncat"
    "neofetch"
    "nmap"
    "nping"
    "nushell.sh"
    "neovim.io"
    "onefetch"
    "packer"
    "pgen"
    "pipx"
    "pre-commit"
    "rclone"
    "rg"
    "scalar"
    "sd"
    "shellcheck"
    "starship"
    "steampipe"
    "stern"
    "tldr"
    "tmux"
    "toast"
    "tofu"
    "tree"
    "trufflehog"
    "tv"
    "updatedb"
    "usql"
    "vals"
    "vault"
    "wget"
    "when"
    "xargs"
    "xcfile.dev"
    "yazi"
    "yj"
    "zap"
    "zellij"
    "zoxide"
    # linux only packages
    "make"
    "unzip"
)

echo_with_color "32" "Installing pkgx packages..."

# Iterate over the packages and install one by one
for package in "${packages[@]}"; do
    # Capture the output of the package installation
    output=$(pkgx install "${package}" 2>&1)

    if [[ "${output}" == *"pkgx: installed:"* ]]; then
        echo "${package} installed successfully"
    elif [[ "${output}" == *"pkgx: already installed:"* ]]; then
        echo_with_color "34" "${package} is already installed."
    else
        echo "Failed to install ${package}"
    fi
done

# Add $HOME/.local/bin to PATH if it's not already there
add_to_path "$HOME/.local/bin"

echo_with_color "32" "pkgx installation complete."

#######################
#  Install dotfiles   #
#######################

# Define the source directory of your dotfiles and the target .config directory
DOTFILES_DIR="$HOME/dotfiles"
CONFIG_DIR="$HOME/.config"

# Create the .config directory if it doesn't exist
if [ ! -d "$CONFIG_DIR" ]; then
    echo_with_color "32" "Creating $CONFIG_DIR..."
    mkdir -p "$CONFIG_DIR"
fi

# Copy each folder from dotfiles to the .config directory
for folder in "$DOTFILES_DIR"/*; do
    if [ -d "$folder" ]; then
        folder_name=$(basename "$folder")
        echo_with_color "32" "Copying $folder_name to $CONFIG_DIR..."
        cp -r "$folder" "$CONFIG_DIR/$folder_name"
    fi
done

# Copy the .zshrc file to the home directory
echo_with_color "32" "Copying .*rc files to $HOME..."
cp -f "$DOTFILES_DIR/.zshrc" "$HOME/.zshrc"
cp -f "$DOTFILES_DIR/.nanorc" "$HOME/.nanorc"

echo_with_color "32" "Installation of dotfiles complete."

#######################
#   Install node      #
#######################

# Function to initialize fnm for the current session
initialize_fnm_for_session() {
    # Specify the shell directly if fnm can't infer it
    local SHELL_NAME="zsh"
    eval "$(fnm env --use-on-cd --shell=${SHELL_NAME})"
}

# Check if npm is installed and working
if ! command_exists npm; then
    echo_with_color "31" "npm could not be found"

    # Attempt to fix fnm command availability
    attempt_fix_command fnm "$HOME/.local/bin"

    # Check for fnm again
    if command_exists fnm; then
        echo_with_color "33" "Found fnm, attempting to install Node.js ${NODE_VERSION}..."
        if fnm install "${NODE_VERSION}"; then
            echo_with_color "32" "Node.js ${NODE_VERSION} installed successfully"

            # Initialize fnm for the current session
            initialize_fnm_for_session

            if fnm use "${NODE_VERSION}"; then
                echo_with_color "32" "Node.js ${NODE_VERSION} is now in use"
            else
                exit_with_error "Failed to use Node.js ${NODE_VERSION}, please check fnm setup"
            fi
        else
            exit_with_error "Failed to install Node.js ${NODE_VERSION}, please check fnm setup"
        fi
    else
        exit_with_error "fnm is still not found after attempting to fix the PATH. Please install Node.js to continue."
    fi
else
    echo_with_color "32" "npm is already installed and working."
fi

# List of packages to install
packages=(
    "aicommits"
    "awsp"
    "neovim"
    "opencommit"
    "pm2"
    "kubelive"
    "gtop"
    "lineselect"

)

echo_with_color "36" "Installing npm global packages..."

# Iterate over the packages and install one by one
for package in "${packages[@]}"; do
    if npm install -g "${package}"; then
        echo_with_color "32" "${package} installed successfully"
    else
        echo_with_color "31" "Failed to install ${package}"
        exit 1
    fi
done

echo_with_color "32" "npm global packages installation complete."

#######################
#  Install terraform  #
#######################

tfenv_install() {
    if ! command_exists git; then
        exit_with_error "git not found. Please install git first."
    else
        # Clone tfenv into ~/.tfenv
        git clone --depth=1 https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
        # Create symlink in a directory that is on the user's PATH
        # Ensure the directory exists and is on PATH
        TFENV_BIN="$HOME/.local/bin"
        mkdir -p "$TFENV_BIN"
        ln -s ~/.tfenv/bin/* "$TFENV_BIN"
        # Add directory to PATH if it's not already there
        add_to_path_exact_match "$TFENV_BIN"
    fi
}

if [[ -z "${TF_VERSION}" ]]; then
    exit_with_error "TF_VERSION is not set. Please set TF_VERSION to the desired Terraform version."
fi

# Check if Terraform is installed and working
if ! command_exists terraform; then
    echo_with_color "33" "Terraform could not be found."
    if command_exists tfenv; then
        echo_with_color "32" "tfenv is already installed."
    else
        tfenv_install
    fi

    echo_with_color "32" "Successfully installed tfenv. Attempting to install Terraform ${TF_VERSION}..."
    if tfenv install "${TF_VERSION}"; then
        installed_version=$(terraform version | head -n 1)
        echo_with_color "32" "Installed Terraform version $installed_version successfully."
        if tfenv use "${TF_VERSION}"; then
            echo_with_color "32" "Terraform ${TF_VERSION} is now in use."
        else
            exit_with_error "Failed to use Terraform ${TF_VERSION}, please check tfenv setup."
        fi
    else
        exit_with_error "Failed to install Terraform ${TF_VERSION}, please check tfenv setup."
    fi
else
    echo_with_color "32" "Terraform is already installed and working."
fi

echo_with_color "32" "Terraform installation complete."

#######################
#  Install python     #
#######################

if ! command_exists curl; then
    echo_with_color "33" "curl is not installed. Installing curl..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install curl -y || exit_with_error "Failed to install curl. Exiting."
fi

# Install pyenv on ubuntu if it is not already installed
if ! command_exists pyenv; then
    echo_with_color "32" "pyenv could not be found"

    # Check for curl
    if command_exists curl; then
        echo_with_color "32" "Found curl, attempting to install pyenv and dependencies..."
        # remove .pyenv if it exists
        rm -rf ~/.pyenv
        sudo apt update
        sudo apt install -y build-essential libssl-dev zlib1g-dev \
            libbz2-dev libreadline-dev libsqlite3-dev curl \
            libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev
        if curl https://pyenv.run | bash; then
            echo_with_color "32" "pyenv installed successfully"

            # Initialize pyenv for the current session
            export PYENV_ROOT="$HOME/.pyenv" # homebrew
            export PATH="$PYENV_ROOT/bin:$PATH"
            eval "$(pyenv init --path)"
            eval "$(pyenv init -)"

            if pyenv install "${PYTHON_VERSION}"; then
                echo_with_color "32" "Python ${PYTHON_VERSION} installed successfully"

                if pyenv global "${PYTHON_VERSION}"; then
                    echo_with_color "32" "Python ${PYTHON_VERSION} is now in use"
                else
                    exit_with_error "Failed to use Python ${PYTHON_VERSION}, please check pyenv setup"
                fi
            else
                exit_with_error "Failed to install Python ${PYTHON_VERSION}, please check pyenv setup"
            fi
        else
            exit_with_error "Failed to install pyenv, please check curl setup"
        fi
    else
        exit_with_error "curl and pyenv not found. Please install Python to continue."
    fi
else
    echo_with_color "32" "pyenv is already installed and working."
fi

echo_with_color "32" "Python installation complete."

#######################
#  Install pip pkgs   #
#######################

# Pip packages to install
pip_packages=(
    "ansible"
    "gita"
    "pip-autoremove"
    "python-sysinformer"
    "sourcery"
    "spotify_to_ytmusic"
    "grafana-backup"
)

initialize_pip() {
    # Check for pip in the common installation locations
    if command_exists pip; then
        echo_with_color "32" "pip is already installed."
    else
        # Attempt to initialize pip if it's installed but not in the PATH
        if [[ -x "$HOME/.pyenv/shims/pip" ]]; then
            export PYENV_ROOT="$HOME/.pyenv"
            export PATH="$PYENV_ROOT/bin:$PATH"
            eval "$(pyenv init --path)"
            eval "$(pyenv init -)"
        else
            # pip is not installed, provide instructions to install it
            echo_with_color "33" "pip is not installed."
            exit_with_error "pip installation required"
        fi
    fi
}

# Function to confirm Python version and pip availability
confirm_python_and_pip() {
    local version
    version=$(python -V 2>&1 | awk '{print $2}')
    if [[ "$version" == "${PYTHON_VERSION}" ]]; then
        echo_with_color "32" "Confirmed Python version ${version}."
    else
        exit_with_error "Python version ${version} does not match the desired version ${PYTHON_VERSION}."
    fi

    if command_exists pip; then
        echo_with_color "32" "pip is available."
    else
        exit_with_error "pip is not available."
    fi
}

# Function to install pip packages
install_pip_packages() {
    for package in "${pip_packages[@]}"; do
        if pip install "${package}"; then
            echo_with_color "32" "${package} installed successfully."
        else
            echo_with_color "31" "Failed to install ${package}."
        fi
    done
}

initialize_pip
confirm_python_and_pip
install_pip_packages

echo_with_color "32" "pip packages installation complete."

#######################
#  Install pipx pkgs  #
#######################

# List of packages to install
packages=(
    "poetry"
    "pyinfra"
)

install_pipx_packages() {
    # Iterate over the packages and install one by one
    for package in "${packages[@]}"; do
        if pipx install "${package}"; then
            echo_with_color "32" "${package} installed successfully"
        else
            echo_with_color "31" "Failed to install ${package}"
            exit 1
        fi
    done
}

# Check if pipx is installed
if command_exists pipx; then
    install_pipx_packages
else
    echo_with_color "31" "pipx command not found, attempting to fix..."

    # Attempt to fix pipx command availability
    attempt_fix_command pipx "$HOME/.local/bin"

    # Check for pipx again
    if command_exists pipx; then
        install_pipx_packages
    else
        exit_with_error "pipx is still not found after attempting to fix the PATH. Please install pipx to continue."
    fi
fi

#########################
# Install micro plugins #
#########################

attempt_fix_command "micro" "$HOME/.local/bin"

# List of plugins to install
plugins=(
    "aspell"
    "yapf"
    "bookmark"
    "bounce"
    "filemanager"
    "fish"
    "fzf"
    "go"
    "jump"
    "lsp"
    "manipulator"
    "misspell"
    "nordcolors"
    "quoter"
    "snippets"
    "wc"
    "autoclose"
    "comment"
    "diff"
    "ftoptions"
    "linter"
    "literate"
    "status"
)

# Iterate over the plugins and install one by one
for plugin in "${plugins[@]}"; do
    if micro -plugin install "${plugin}"; then
        echo_with_color "32" "${plugin} installed successfully"
    else
        echo_with_color "32" "Failed to install ${plugin}"
    fi
done

echo_with_color "32" "micro plugins installation complete."

#######################
#    Install ruby     #
#######################

# Function to install rbenv using the official installer script on Linux
install_rbenv() {
    if ! command_exists curl; then
        echo_with_color "33" "curl is not installed. Installing curl..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get install curl -y || exit_with_error "Failed to install curl. Exiting."
    fi

    # Install dependencies for rbenv and Ruby build
    sudo apt update || exit_with_error "Failed to update apt."
    sudo apt install -y git curl autoconf bison build-essential libssl-dev libyaml-dev \
        libreadline6-dev zlib1g-dev libncurses5-dev libffi-dev libgdbm6 libgdbm-dev libdb-dev ||
        exit_with_error "Failed to install dependencies for rbenv and Ruby build."
    curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash
}

# Function to initialize rbenv within the script
initialize_rbenv() {
    echo_with_color "32" "Initializing rbenv for the current Linux session..."
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"
}

# Function to install Ruby and set it as the global version
install_and_set_ruby() {
    echo_with_color "32" "Installing Ruby version $RUBY_VERSION..."
    rbenv install $RUBY_VERSION || exit_with_error "Failed to install Ruby version $RUBY_VERSION."
    echo_with_color "32" "Setting Ruby version $RUBY_VERSION as global..."
    rbenv global $RUBY_VERSION || exit_with_error "Failed to set Ruby version $RUBY_VERSION as global."
    echo "Ruby installation completed. Ruby version set to $RUBY_VERSION."
}

if command_exists rbenv; then
    echo_with_color "32" "rbenv is already installed."
else
    install_rbenv || exit_with_error "Failed to install rbenv."
fi

initialize_rbenv
install_and_set_ruby

echo_with_color "32" "Ruby installation complete."

#######################
# Install docker      #
#######################

# Function to check if Docker is already installed
check_docker_installed() {
    if command_exists docker; then
        echo "Docker is already installed."
        docker --version
        return 0
    else
        return 1
    fi
}

# Function to install Docker
install_docker() {
    # Add Docker's official GPG key:
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    # Install Docker Engine
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add the current user to the Docker group to run Docker commands without sudo
    sudo usermod -aG docker "$USER"
    newgrp docker

    # Output the installed Docker version
    docker --version
}

# Main script execution
if check_docker_installed; then
    echo "Skipping installation as Docker is already installed."
else
    echo_with_color "32" "Docker is not installed. Installing Docker..."
    install_docker
    echo_with_color "32" "Installation complete. You may need to log out and back in or restart your system to use Docker as a non-root user."
fi

echo_with_color "32" "Docker installation complete."
