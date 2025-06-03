# IVS-VALT Backup Tool

Intelligent Video Solutions Video Audio Learning Tool Backup Tool

## What it does

Backup all IVS VALT video system recordings.

Windows, Using Powershell 5+, and rsync (provided by msys2)

Linux, using Powershell Core, rsync, ssh (from your package manager)

## Versions Supported

VALT version 6 is supported, see the other branches for older versions.

## Setup

### Setting up the IVS Appliance

#### API User accounts

In the web interface, create a new user that has access to all video files.

#### IVS Software, Sudoers config

1. Generate a ssh key (not in putty format) using the ed25519 algorithm (hardcoded in the script), place `id_ed25519` in the rsync folder in this repo
2. Login to the IVS video appliance via ssh as the ivsadmin user, the default password is `@dmin51!!`. It's worth changing the password if you haven't with the `passwd` command
3. As the user, set the authorised key

   ```bash
   mkdir ~/.ssh
   chmod 700 ~/.ssh
   touch ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

4. Write the public key content from id_ed25519.pub into the file with your favorite terminal text editor (Use nano if you don't know how to use vim). The content should be one line starting with ssh-ed25519
5. Install rsync

   ```bash
   sudo apt install rsync
   ```

6. Use the following command to write a new sudoers rule

   ```bash
   sudo visudo /etc/sudoers.d/rsync
   ```

7. Write the line:

   ```text
   ivsadmin ALL=NOPASSWD: /usr/bin/rsync
   ```

8. Save and exit

### Writing settings.json

With the API user accounts that you made, fill out a new file settings.json per the settingsexample.json example and the following information.

| Field             | Description                                                          |
| ----------------- | -------------------------------------------------------------------- |
| destinationfolder | Destination folder for backup                                        |
| timeouthours      | Max time in hours for the script to run. 0 will run until completion |
| shareddiveletter  | Drive letter to mount                                                |
| sharedfolderpath  | Network path to mount on shareddiveletter                            |
| sites             | List of sites, see next subsection                                   |

If you are backing up to local storage, leave `shareddiveletter` and `sharedfolderpath` blank.

#### Sites

You can think of sites as individual IVS VALT servers to backup.

| Field    | Description                                                                    |
| -------- | ------------------------------------------------------------------------------ |
| sitename | Name of the site of the appliance, will be a folder name in the backups folder |
| fqdn     | fqdn of the appliance, IP address or hostname works too probably               |
| user     | username for user account on valt, I use `apiuser_admin` as my service account |
| password | password for the ivs service account user                                      |

### Rsync Windows Guide

This tool requires the msys2 version of rsync. Previously this used cygwin, but would cause ACL issues in windows.

- Download and install msys2

- Open a msys2 shell (msys2 msys), run the commands:

```bash
pacman -Syyu
# msys will probably restart
pacman -Sy rsync openssh
```

- Grab ssh.exe, rsync.exe and rsync-ssl form C:\msys64\usr\bin and place them here in the rsync directory of this repo folder.

- Use [depends.exe](https://www.dependencywalker.com/) to figure out what libs need to come from `C:\msys64\usr\bin`
  - All the dlls that you need will start with 'msys'
  - Ignore anything missing under kernel32.dll, this belongs to windows and will be just fine on any working windows system
  - If you are lazy, you can just grab every dll when searching msys\*.dll probably

As of 2024, my setup looks like this:

```text
msys-2.0.dll
msys-asn1-8.dll
msys-com_err-1.dll
msys-crypt-2.dll
msys-crypto-3.dll
msys-gcc_s-seh-1.dll
msys-gssapi-3.dll
msys-hcrypto-4.dll
msys-heimbase-1.dll
msys-heimntlm-0.dll
msys-hx509-5.dll
msys-iconv-2.dll
msys-krb5-26.dll
msys-lz4-1.dll
msys-roken-18.dll
msys-sqlite3-0.dll
msys-wind-0.dll
msys-xxhash-0.dll
msys-z.dll
msys-zstd-1.dll
rsync-ssl
rsync.exe
ssh.exe
```

## Running

```powershell

# Run specifying the config file location, runs rsync in test mode
.\backup_ivs.ps1 -config c:\path\to\settings.json

# Run without downloading video, run dry-run rsync to simulate, show debug messages, download metadata
.\backup_ivs.ps1 -noisy

# Run without downloading video and don't waste time doing a dry-run with rsync, download metadata. Can't be used with -production
.\backup_ivs.ps1 -metadataonly

# Run actually download the files
.\backup_ivs.ps1 -production
```

### Scheduling the run

Edit the script create_job.ps1 with the correct parameters and run. A scheduled task called "Backup-IVS" will be created
