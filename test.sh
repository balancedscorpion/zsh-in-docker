#!/usr/bin/env bash

source ./assert.sh

set -e

trap 'docker compose stop -t 1' EXIT INT

#Different create_user commands for different distributions
create_user() {
    container=$1
    username=$2

    # Check if the user already exists
    if docker exec $container id -u $username >/dev/null 2>&1; then
        echo "User $username already exists"
        return 0
    fi

    # Try to determine the distribution
    if docker exec $container cat /etc/os-release | grep -q "ID=alpine"; then
        docker exec $container adduser -D $username
    elif docker exec $container cat /etc/os-release | grep -q "ID=amzn"; then
        # For Amazon Linux
        docker exec $container useradd -m $username
    else
        # For most other distributions
        docker exec $container useradd -m $username || docker exec $container adduser --disabled-password --gecos "" $username
    fi

    if [ $? -ne 0 ]; then
        echo "Error: Unable to create user $username"
        return 1
    fi
}

test_suite() {
    image_name=$1
    user_type=$2

    echo
    echo "########## Testing in a $image_name container as $user_type"
    echo

    set -x

    docker compose rm --force --stop test-$image_name || true
    docker compose up -d test-$image_name

    docker cp zsh-in-docker.sh zsh-in-docker-test-${image_name}-1:/tmp

    if [ "$user_type" = "non-root" ]; then
        # Create a non-root user
        create_user zsh-in-docker-test-${image_name}-1 dockeruser
        docker exec zsh-in-docker-test-${image_name}-1 sh /tmp/zsh-in-docker.sh \
            -t https://github.com/denysdovhan/spaceship-prompt \
            -p git -p git-auto-fetch \
            -p https://github.com/zsh-users/zsh-autosuggestions \
            -p https://github.com/zsh-users/zsh-completions \
            -a 'CASE_SENSITIVE="true"' \
            -a 'HYPHEN_INSENSITIVE="true"' \
            -u dockeruser
    else
        docker exec zsh-in-docker-test-${image_name}-1 sh /tmp/zsh-in-docker.sh \
            -t https://github.com/denysdovhan/spaceship-prompt \
            -p git -p git-auto-fetch \
            -p https://github.com/zsh-users/zsh-autosuggestions \
            -p https://github.com/zsh-users/zsh-completions \
            -a 'CASE_SENSITIVE="true"' \
            -a 'HYPHEN_INSENSITIVE="true"'
    fi

    set +x

    echo

    VERSION=$(docker exec zsh-in-docker-test-${image_name}-1 zsh --version)
    
    if [ "$user_type" = "non-root" ]; then
        ZSHRC=$(docker exec zsh-in-docker-test-${image_name}-1 cat /home/dockeruser/.zshrc)
        HOME_DIR="/home/dockeruser"
    else
        ZSHRC=$(docker exec zsh-in-docker-test-${image_name}-1 cat /root/.zshrc)
        HOME_DIR="/root"
    fi

    echo "########################################################################################"
    echo "$ZSHRC"
    echo "########################################################################################"

    echo "Test: zsh 5 was installed" && assert_contain "$VERSION" "zsh 5" "!"
    echo "Test: ~/.zshrc was generated" && assert_contain "$ZSHRC" "ZSH=\"$HOME_DIR/.oh-my-zsh\"" "!"
    echo "Test: theme was configured" && assert_contain "$ZSHRC" 'ZSH_THEME="spaceship-prompt/spaceship"' "!"
    echo "Test: plugins were configured" && assert_contain "$ZSHRC" 'plugins=(git git-auto-fetch zsh-autosuggestions zsh-completions )' "!"
    echo "Test: line 1 is appended to ~/.zshrc" && assert_contain "$ZSHRC" 'CASE_SENSITIVE="true"' "!"
    echo "Test: line 2 is appended to ~/.zshrc" && assert_contain "$ZSHRC" 'HYPHEN_INSENSITIVE="true"' "!"
    echo "Test: newline is expanded when append lines" && assert_not_contain "$ZSHRC" '\nCASE_SENSITIVE="true"' "!"

    if [ "$user_type" = "non-root" ]; then
        echo "Test: .zshrc owner is dockeruser" && assert_contain "$(docker exec zsh-in-docker-test-${image_name}-1 ls -l /home/dockeruser/.zshrc)" "dockeruser" "!"
        echo "Test: .oh-my-zsh owner is dockeruser" && assert_contain "$(docker exec zsh-in-docker-test-${image_name}-1 ls -ld /home/dockeruser/.oh-my-zsh)" "dockeruser" "!"
    fi

    echo
    echo "######### Success! All tests are passing for ${image_name} as ${user_type}"
    docker compose stop -t 1 test-$image_name
}

images=${*:-"alpine ubuntu ubuntu-14.04 debian amazonlinux centos7 rockylinux8 rockylinux9 fedora"}

for image in $images; do
    test_suite $image "root"
    test_suite $image "non-root"
done