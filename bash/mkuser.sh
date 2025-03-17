#!/bin/bash


### Script Variables ###

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PATH="${SELF%/*}:$PATH"

PROGRAM="${0##./}"
ARGS=( "$@" )

user=${1}
group=${1}

homeRootDirectory="/home"
homeDirectoryName=""

isSamba=1
sambaDirectoryName="samba"

isSftp=1
sftpDirectoryName="sftp"

startupScript="${BASH}"

GROUP_CREATION_FAILURE_EXIT_CODE=41
HELP_EXIT_CODE=0
MISSING_USERNAME_ARGUMENT_EXIT_CODE=1
UNKNOWN_ARGUMENT_EXIT_CODE=2
USER_CREATION_FAILURE_EXIT_CODE=31
USER_HOME_FAILURE_EXIT_CODE=32
USER_PASSWORD_FAILURE_EXIT_CODE=33

### Define Functions ###

AddUser()
{
    `useradd -g ${2} -d ${3} -s ${4} ${1}`
    return ${?}
}

AddGroup()
{
    `groupadd ${1}`
    echo ${?}
}

AutoSu()
{
    [[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"
}

CheckArgs()
{
    if [ $# -eq 0 ]; then
        echo -e "Error $MISSING_USERNAME_ARGUMENT_EXIT_CODE: $PROGRAM needs atleast 1 argument\n"
        DisplayHelp
        exit $MISSING_USERNAME_ARGUMENT_EXIT_CODE
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -g|--group)
                group=$2
                
                shift # past argument
                shift # past value
            ;;
            
            -h|--help)
                DisplayHelp
                exit $HELP_EXIT_CODE
            ;;
            
            --home-directory-name)
                homeDirectoryName="$2"
                
                shift # past argument
                shift # past value
            ;;
            
            --home-location)
                homeRootDirectory="$2"
                
                shift # past argument
                shift # past value
            ;;
            
            --no-login)
                startupScript="/sbin/nologin"

                shift # past argument
            ;;

#            --samba)
#                isSamba=0
#
#                shift # past argument
#            ;;
            
#            --samba-directory)
#                isSamba=0
#                sambaDirectoryName="$2"
#                
#                shift # past argument
#                shift # past value
#            ;;
            
            --sftp)
                isSftp=0

                shift # past argument
            ;;
            
            --sftp-directory)
                isSftp=0
                sftpDirectoryName="$2"
                
                shift # past argument
                shift # past value
            ;;
            
            -*|--*)
                echo "Unknown option $1"
                exit $UNKNOWN_ARGUMENT_EXIT_CODE
            ;;
            
            *)
                if [ $# -eq 1 ]; then
                    user=$1
                else
                    echo "A username is requested to create the user"
                    exit $MISSING_USERNAME_ARGUMENT_EXIT_CODE
                fi
                
                POSITIONAL_ARGS+=("$1") # save positional arg
                shift # past argument
            ;;
        esac
    done

    set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
    
    if [ $isSftp ]; then
        startupScript="/sbin/nologin"
    fi
}

DisplayHelp()
{
    echo -e "$PROGRAM [-d|--home-path absolute_path] [-g|--group group_name] [--no-login] <user_name>.\n"
    echo -e "  -g | --group\n\tSet user's group. If the group doesn't exist, it is created. Default group is <user_name>.\n"
    echo -e "  -h | --help\n\tDisplay this command list.\n"
    echo -e "  --home-directory-name\n\tSet user's home directory name. Default is <user_name>.\n"
    echo -e "  --home-location\n\tSet user's home location path. Absolute path expected. Default path is /home.\n"
    echo -e "  --no-login\n\tDisable login. Implied with --sftp and --sftp-directory options.\n"
#    echo -e "  --samba\n\tAdd a \"samba\" directory in the user's home directory. Directory name can be changed using --samba-directory option.\n"
#    echo -e "  --samba-directory-name\n\tSet the samba directory name. Relative path expected. Implied --samba option.\n"
    echo -e "  --sftp\n\tAdd a \"sftp\" directory in the user's home directory. Directory name can be changed using --sft-directory option. Implied --no-login option.\n"
    echo -e "  --sftp-directory-name\n\tSet the sftp directory name. Relative path expected. Implied --sftp and --no-login options\n"
}

GroupExists()
{
    local groupExists=`cat "/etc/group" | grep "${1}"`
    
    if [ "${groupExists}" == "" ]; then
        echo 1
    else
        echo 0
    fi
}

MakeDirectory()
{
    if [ ! -d ${1} ]; then
        `mkdir -p ${1}`
        echo ${?}
    else
        echo 0
    fi
}

SetDirectoryOwner()
{
    `chown ${1}:${2} ${3}`
    echo ${?}
}

SetUserPasswd()
{
    `passwd ${1}`
    echo ${?}
}

### Script starts here ###

CheckArgs $@

### Set directory path ###

if [ "$homeDirectoryName" == "" ]; then
    homeDirectoryName=$user
fi

if [ $isSftp -eq 0 ]; then
    directory=${homeRootDirectory}/${homeDirectoryName}/${sftpDirectoryName}
    passwdDirectory=/$sftpDirectoryName
elif [ $isSamba -eq 0 ]; then
    directory=${homeRootDirectory}/${homeDirectoryName}/${sambaDirectoryName}
    passwdDirectory=/$sambaDirectoryName
else
    directory=${homeRootDirectory}/${homeDirectoryName}
    passwdDirectory=$directory
fi

AutoSu

### Check and create the group if necessary

echo "Checking group..."

groupExists=$(GroupExists ${group})

if [ $groupExists -ne 0 ]; then
    echo "Creating group ${group}..."
    groupExists=$(AddGroup ${group})
    
    if [ $groupExists ]; then
        echo -ne "...[ok]\n\n"
    else
        echo -ne "...[failed]\nError ${GROUP_CREATION_FAILURE_EXIT_CODE}: group doesn't exist and can't be created\n"
        exit ${GROUP_CREATION_FAILURE_EXIT_CODE}
    fi
else
    echo -ne "...[ok]\n\n"
fi

### Create User ###

echo "Creating user ${user}..."

if ! AddUser ${user} ${group} ${passwdDirectory} ${startupScript} ; then
    echo -ne "...[failed]\n"
    read -r -p "Try again ? [y/N] " retry

    case $retry in
        [yY][eE][sS]|[yY])
            if ! AddUser ${user} ${group} ${directory} ${startupScript} ; then
                echo "Error ${USER_CREATION_FAILURE_EXIT_CODE}: attempt over, please verify the username."
                exit $USER_CREATION_FAILURE_EXIT_CODE
            fi
        break
        ;;

        [nN][oO]|[nN])
            exit $USER_CREATION_FAILURE_EXIT_CODE
            break
        ;;

        *)
            exit $USER_CREATION_FAILURE_EXIT_CODE
        ;;
    esac
fi
echo -ne "...[ok]\n\n"

### Set User Password ###

echo "Setting ${user}'s password..."
echo "Generated random passwords:"
echo `date | sha256sum | md5sum | base64 -w 12`
echo -ne "\n"

passwdResult=$(SetUserPasswd ${user})

while [ ${passwdResult} -ne 0 ]
do
    read -r -p "Try again ? [Y/n] " retry

    case $retry in
        [yY][eE][sS]|[yY])
            echo "Let's try again !"
            passwdResult=$(SetUserPasswd ${user})
        break
        ;;

        [nN][oO]|[nN])
            exit $USER_PASSWORD_FAILURE_EXIT_CODE
        break
        ;;

        *)
            echo "Let's try again !"
            passwdResult=$(SetUserPasswd ${user})
        ;;
    esac
done
echo -ne "...[ok]\n\n"


### Make User Directory ###

echo "Making ${user}'s home directory at ${directory}..."
mkdirResult=$(MakeDirectory ${directory})

while [ ${mkdirResult} -ne 0 ]; do
    echo -ne "...[failed]\n\n"
    read -r -p "Try again ? [Y/n] " retry

    case $retry in
        [yY][eE][sS]|[yY])
            echo "Let's try again !"
            mkdirResult=$(MakeDirectory ${directory})
        break
        ;;

        [nN][oO]|[nN])
            exit $USER_HOME_FAILURE_EXIT_CODE
        break
        ;;

        *)
            echo "Let's try again !"
            mkdirResult=$(MakeDirectory ${directory})
        ;;
    esac
done
echo -ne "...[ok]\n\n"

### Set Directory Owner ###

echo "Setting directory owner..."
chownResult=$(SetDirectoryOwner ${user} ${group} ${directory})

while [ ${chownResult} -ne 0 ]; do
    echo -ne "...[failed]\n\n"
    read -r -p "Try again ? [Y/n] " retry

    case $retry in
        [yY][eE][sS]|[yY])
            echo "Let's try again !"
            chownResult=$(SetDirectoryOwner ${user} ${group} ${directory})
        break
        ;;

        [nN][oO]|[nN])
            exit $USER_HOME_FAILURE_EXIT_CODE
        break
        ;;

        *)
            echo "Let's try again !"
            chownResult=$(SetDirectoryOwner ${user} ${group} ${directory})
        ;;
    esac
done
echo -ne "...[ok]\n\n"

echo "Finished!"
exit 0
