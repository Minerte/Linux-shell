#!/bin/bash

openrc_runtime () {
    echo "updating openrc init"
    echo "remove runtime"
    rc-service dhcpcd stop || { echo "rc-service dhcpcd stop failed"; exit 1; }
    rc-update del hostname boot || { echo "rc-update del hostname boot failed"; exit 1; }
    sleep 3

    echo "default level"
    rc-update add dbus default || { echo "rc-update add dbus default failed"; exit 1; }
    rc-update add seatd default || { echo "rc-updte add seatd default failed"; exit 1; }
    rc-update add cronie default || { echo "rc-update add cronie default failed"; exit 1; }
    rc-update add chronyd default || { echo "rc-update add chronyd default failed"; exit 1; }
    rc-update add sysklogd default || { echo "rc-update add sysklogd default failed"; exit 1; }
    rc-update add NetworkManager default || { echo "rc-update add NetworkManager default failed"; exit 1; }
    sleep 3

    echo "Editing for Networkmanager"
    echo "Wating 5s to make sure"
    sleep 5

    get_input() {   
        local prompt="$1"
        local var
        read -rp "$prompt" var
        echo "$var"
    }

    CUSTOM_HOSTNAME=$(get_input "Enter the hostname you want to set: ")

    while true; do
        HOSTNAME_MODE=$(get_input "Choose hostname mode (dhcp/always): ")
        if [[ "$HOSTNAME_MODE" == "dhcp" || "$HOSTNAME_MODE" == "always" ]]; then
            break
        else
            echo "Invalid choice! Please enter 'dhcp' or 'always'."
        fi
    done

    nmcli general hostname "$CUSTOM_HOSTNAME" || { echo "Failed to create custom hostname"; exit 1; }
    CONFIG_DIR="/etc/NetworkManager/conf.d"
    CONFIG_FILE="$CONFIG_DIR/hostname.conf"

    mkdir -p "$CONFIG_DIR" || { echo "Failed to create directory for $CONFIG_DIR"; exit 1; }
    echo -e "[main]\nhostname=$CUSTOM_HOSTNAME" > "$CONFIG_FILE" || { echo "Failed put $CUSTOM_HOSTNAME in $CONFIG_FILE"; exit 1; }
    
    NM_MAIN_CONFIG="/etc/NetworkManager/NetworkManager.conf"
    touch "$NM_MAIN_CONFIG" || { echo "Failed to create file $NM_MAIN_CONFIG"; exit 1; }
    sed -i '/^hostname-mode=/d' "$NM_MAIN_CONFIG" || { echo "Failed to edit file $NM_MAIN_CONFIG"; exit 1; }

    # Add the new hostname-mode setting
    if ! grep -q "^\[main\]" "$NM_MAIN_CONFIG"; then
      sed -i '1s/^/[main]\n/' "$NM_MAIN_CONFIG"
    fi

    echo "hostname-mode=$HOSTNAME_MODE" >> "$NM_MAIN_CONFIG"

    echo "-------------------------------------------"
    echo "New hostname set to: $CUSTOM_HOSTNAME"
    echo "Hostname mode set to: $HOSTNAME_MODE"
    echo "NetworkManager succesfully configured"
    echo "-------------------------------------------"
}

config_for_session() {
    echo "Config doas"
    echo "permit persist :wheel" >> /etc/doas.conf
    chown -c root:root /etc/doas.conf
    chmod 0400 /etc/doas.conf
    echo "/etc/doas.conf permission is now set as root:root 0400"

    echo "Making root password"
    while true; do
        echo "Type yours password for root"
        passwd root
        if [ $? -eq 0 ]; then
            echo "Root password set successfully."
            break
        else
            echo "Failed to set root password. Please try again."
        fi
    done

    echo "Adding user"
    while true; do
        read -rp "Enter the username: " user_acc

        if [ -z "$user_acc" ]; then
            echo "Username cannot be empty. try again."
        else
            break
        fi
    done

    useradd -m -G users,wheel,seat,disk,input,cdrom,floppy,audio,video -s /bin/bash "$user_acc"

    if [ $? -eq 0 ]; then
        echo "User $user_acc created successfully."
    else
        echo "Failed to create user $user_acc."
        exit 1
    fi

    while true; do
        echo "Setting password for $user_acc:"
        passwd "$user_acc"
        if [ $? -eq 0 ]; then
            echo "Password for $user_acc set successfully."
            break
        else
            echo "Failed to set password for $user_acc. Please try again."
        fi
    done

    echo "Config for session is now done"

}