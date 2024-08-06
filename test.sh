#!/bin/sh

# Don't exit immediately on error
set +e

FAILED_TESTS=0

run_test() {
    if eval "$@"; then
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
    run_test "docker exec $container su - $user -c 'which zsh' | grep -q zsh"

    # Check if the user's shell is set to zsh
    run_test "docker exec $container getent passwd $user | cut -d: -f7 | grep -q zsh"

    # Check zsh version
    run_test "docker exec $container su - $user -c 'zsh --version' | grep -q 'zsh 5'"

    # Check .zshrc content
    run_test "docker exec $container grep -q 'ZSH=\"$home_dir/.oh-my-zsh\"' $home_dir/.zshrc"
    run_test "docker exec $container grep -q 'ZSH_THEME=\"spaceship-prompt/spaceship\"' $home_dir/.zshrc"
    run_test "docker exec $container grep -q 'plugins=(git git-auto-fetch zsh-autosuggestions zsh-completions )' $home_dir/.zshrc"
    run_test "docker exec $container grep -q 'CASE_SENSITIVE=\"true\"' $home_dir/.zshrc"
    run_test "docker exec $container grep -q 'HYPHEN_INSENSITIVE=\"true\"' $home_dir/.zshrc"

    # Check if Oh My Zsh is installed for the user
    run_test "docker exec $container test -d $home_dir/.oh-my-zsh"
}

test_user() {
    image_name=$1
    user_type=$2
    container="zsh-in-docker-test-${image_name}-1"

    echo
    echo "########## Testing in a $image_name container as $user_type"
    echo

    docker compose rm --force --stop test-$image_name || true
    docker compose up -d test-$image_name

    docker cp zsh-in-docker.sh $container:/tmp

    if [ "$user_type" = "non-root" ]; then
        create_user $container "dockeruser"
        run_zsh_install $container "dockeruser" "/home/dockeruser"
        test_zsh_installation $container "dockeruser" "/home/dockeruser"
        
        # Additional non-root specific tests
        run_test "docker exec $container ls -l /home/dockeruser/.zshrc | grep -q dockeruser"
        run_test "docker exec $container ls -ld /home/dockeruser/.oh-my-zsh | grep -q dockeruser"
    else
        run_zsh_install $container "" "/root"
        test_zsh_installation $container "root" "/root"
    fi

    echo
    if [ $FAILED_TESTS -eq 0 ]; then
        echo "######### Success! All $user_type tests are passing for ${image_name}"
    else
        echo "######### Failure! $FAILED_TESTS test(s) failed for $user_type on ${image_name}"
    fi
    docker compose stop -t 1 test-$image_name
}

images=${*:-"alpine ubuntu ubuntu-14.04 debian amazonlinux centos7 rockylinux8 rockylinux9 fedora"}

TOTAL_FAILED_TESTS=0

for image in $images; do
    FAILED_TESTS=0
    test_user $image "root"
    TOTAL_FAILED_TESTS=$((TOTAL_FAILED_TESTS + FAILED_TESTS))
    
    FAILED_TESTS=0
    test_user $image "non-root"
    TOTAL_FAILED_TESTS=$((TOTAL_FAILED_TESTS + FAILED_TESTS))
done

echo
echo "Test suite completed. Total failed tests: $TOTAL_FAILED_TESTS"

if [ $TOTAL_FAILED_TESTS -gt 0 ]; then
    exit 1
else
    exit 0
fi