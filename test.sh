#!/usr/bin/env bash

source ./assert.sh

# Don't exit immediately on error
set +e

trap 'docker compose stop -t 1' EXIT INT

run_test() {
    if "$@"; then
        echo "PASS: $*"
    else
        echo "FAIL: $*"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

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
    run_test [ -n "$ZSH_INSTALLED" ]

    # Check if the user's shell is set to zsh
    USER_SHELL=$(docker exec $container getent passwd $user | cut -d: -f7)
    run_test [ "$USER_SHELL" = "/bin/zsh" ]

    VERSION=$(docker exec $container su - $user -c "zsh --version")
    run_test [[ "$VERSION" == *"zsh 5"* ]]

    ZSHRC=$(docker exec $container cat $home_dir/.zshrc)
    run_test [[ "$ZSHRC" == *"ZSH=\"$home_dir/.oh-my-zsh\""* ]]
    run_test [[ "$ZSHRC" == *'ZSH_THEME="spaceship-prompt/spaceship"'* ]]
    run_test [[ "$ZSHRC" == *'plugins=(git git-auto-fetch zsh-autosuggestions zsh-completions )'* ]]
    run_test [[ "$ZSHRC" == *'CASE_SENSITIVE="true"'* ]]
    run_test [[ "$ZSHRC" == *'HYPHEN_INSENSITIVE="true"'* ]]
    run_test [[ "$ZSHRC" != *$'\nCASE_SENSITIVE="true"'* ]]

    # Check if Oh My Zsh is installed for the user
    OH_MY_ZSH_DIR=$(docker exec $container su - $user -c "echo \$ZSH")
    run_test docker exec $container test -d "$OH_MY_ZSH_DIR"
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
    if [ $FAILED_TESTS -eq 0 ]; then
        echo "######### Success! All root user tests are passing for ${image_name}"
    else
        echo "######### Failure! $FAILED_TESTS test(s) failed for root user on ${image_name}"
    fi
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
    run_test docker exec $container ls -l /home/dockeruser/.zshrc | grep -q dockeruser
    run_test docker exec $container ls -ld /home/dockeruser/.oh-my-zsh | grep -q dockeruser

    echo
    if [ $FAILED_TESTS -eq 0 ]; then
        echo "######### Success! All non-root user tests are passing for ${image_name}"
    else
        echo "######### Failure! $FAILED_TESTS test(s) failed for non-root user on ${image_name}"
    fi
    docker compose stop -t 1 test-$image_name
}

images=${*:-"alpine ubuntu ubuntu-14.04 debian amazonlinux centos7 rockylinux8 rockylinux9 fedora"}

TOTAL_FAILED_TESTS=0

for image in $images; do
    FAILED_TESTS=0
    test_root_user $image
    TOTAL_FAILED_TESTS=$((TOTAL_FAILED_TESTS + FAILED_TESTS))
    
    FAILED_TESTS=0
    test_non_root_user $image
    TOTAL_FAILED_TESTS=$((TOTAL_FAILED_TESTS + FAILED_TESTS))
done

echo
echo "Test suite completed. Total failed tests: $TOTAL_FAILED_TESTS"

if [ $TOTAL_FAILED_TESTS -gt 0 ]; then
    exit 1
else
    exit 0
fi