#!/usr/bin/env bash

source ./assert.sh

set -e

trap 'docker compose stop -t 1' EXIT INT

identify_os() {
    container=$1
    if docker exec $container sh -c "[ -f /etc/os-release ]"; then
        docker exec $container sh -c "cat /etc/os-release" | grep -E "^ID=" | cut -d= -f2 | tr -d '"'
    elif docker exec $container sh -c "[ -f /etc/alpine-release ]"; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

create_user() {
    container=$1
    username=$2
    os=$(identify_os $container)

    case $os in
        alpine)
            docker exec $container adduser -D $username
            ;;
        ubuntu|debian)
            docker exec $container useradd -m $username
            ;;
        amzn|amazonlinux)
            docker exec $container yum install -y shadow-utils
            docker exec $container useradd -m $username
            ;;
        centos|rocky|fedora)
            docker exec $container useradd -m $username
            ;;
        *)
            echo "Error: Unsupported operating system for user creation."
            return 1
            ;;
    esac
}

run_zsh_install() {
    container=$1
    user=$2
    home_dir=$3

    docker exec $container sh /tmp/zsh-in-docker.sh \
        -t https://github.com/denysdovhan/spaceship-prompt \
        -p git -p git-auto-fetch \
        -p https://github.com/zsh-users/zsh-autosuggestions \
        -p https://github.com/zsh-users/zsh-completions \
        -a 'CASE_SENSITIVE="true"' \
        -a 'HYPHEN_INSENSITIVE="true"' \
        ${user:+-u "$user"}
}

test_zsh_installation() {
    container=$1
    user=$2
    home_dir=$3

    echo "Testing zsh installation for $user:"

    # Check if zsh is installed for the user
    ZSH_INSTALLED=$(docker exec $container su - $user -c "which zsh")
    echo "Test: zsh is installed for $user" && assert_not_empty "$ZSH_INSTALLED" "!"

    # Check if the user's shell is set to zsh
    USER_SHELL=$(docker exec $container getent passwd $user | cut -d: -f7)
    echo "Test: $user's shell is set to zsh" && assert_equal "$USER_SHELL" "/bin/zsh" "!"

    VERSION=$(docker exec $container su - $user -c "zsh --version")
    ZSHRC=$(docker exec $container cat $home_dir/.zshrc)

    echo "Test: zsh 5 was installed" && assert_contain "$VERSION" "zsh 5" "!"
    echo "Test: ~/.zshrc was generated" && assert_contain "$ZSHRC" "ZSH=\"$home_dir/.oh-my-zsh\"" "!"
    echo "Test: theme was configured" && assert_contain "$ZSHRC" 'ZSH_THEME="spaceship-prompt/spaceship"' "!"
    echo "Test: plugins were configured" && assert_contain "$ZSHRC" 'plugins=(git git-auto-fetch zsh-autosuggestions zsh-completions )' "!"
    echo "Test: line 1 is appended to ~/.zshrc" && assert_contain "$ZSHRC" 'CASE_SENSITIVE="true"' "!"
    echo "Test: line 2 is appended to ~/.zshrc" && assert_contain "$ZSHRC" 'HYPHEN_INSENSITIVE="true"' "!"
    echo "Test: newline is expanded when append lines" && assert_not_contain "$ZSHRC" '\nCASE_SENSITIVE="true"' "!"

    # Check if Oh My Zsh is installed for the user
    OH_MY_ZSH_DIR=$(docker exec $container su - $user -c "echo \$ZSH")
    echo "Test: Oh My Zsh is installed for $user" && assert_dir_exists "$OH_MY_ZSH_DIR" "!"
}

test_root_user() {
    image_name=$1
    container="zsh-in-docker-test-${image_name}-1"

    echo
    echo "########## Testing in a $image_name container as root"
    echo

    docker compose rm --force --stop test-$image_name || true
    docker compose up -d test-$image_name

    docker cp zsh-in-docker.sh $container:/tmp

    run_zsh_install $container "" "/root"
    test_zsh_installation $container "root" "/root"

    echo
    echo "######### Success! All root user tests are passing for ${image_name}"
    docker compose stop -t 1 test-$image_name
}

test_non_root_user() {
    image_name=$1
    container="zsh-in-docker-test-${image_name}-1"

    echo
    echo "########## Testing in a $image_name container as non-root user"
    echo

    docker compose rm --force --stop test-$image_name || true
    docker compose up -d test-$image_name

    docker cp zsh-in-docker.sh $container:/tmp

    create_user $container "dockeruser"
    run_zsh_install $container "dockeruser" "/home/dockeruser"
    test_zsh_installation $container "dockeruser" "/home/dockeruser"

    # Additional non-root specific tests
    echo "Test: .zshrc owner is dockeruser" && assert_contain "$(docker exec $container ls -l /home/dockeruser/.zshrc)" "dockeruser" "!"
    echo "Test: .oh-my-zsh owner is dockeruser" && assert_contain "$(docker exec $container ls -ld /home/dockeruser/.oh-my-zsh)" "dockeruser" "!"

    echo
    echo "######### Success! All non-root user tests are passing for ${image_name}"
    docker compose stop -t 1 test-$image_name
}

images=${*:-"alpine ubuntu ubuntu-14.04 debian amazonlinux centos7 rockylinux8 rockylinux9 fedora"}

for image in $images; do
    test_root_user $image
    test_non_root_user $image
done