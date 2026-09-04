# Companion Satellite Watchdog Deployment Guide  

### NOTE: This was vibe-coded using AI (Google Gemini).
  
This repository hosts companion_watchdog.sh, an automated, high-signal monitoring, notification, and self-healing framework designed for multi-node **Bitfocus Companion** home lab environments running Linux/RPi.  
  
It uses passive log auditing and proactive network orchestration. The watchdog continuously tails the server's system logs (journalctl) to intercept device disconnections. If a satellite's network socket drops, the script triggers an out-of-band HTTP webhook to the target satellite's localized webhook daemon, forcing an immediate connection recovery.  

Additionally, the engine handles **automated network auto-discovery** via socket mapping and dispatches **custom-formatted email notifications** via Postfix/AWS SES if an inventory item fails to restore connection blocks within your chosen grace window.  
  
This has only been tested on RPI with Elgato Streamdecks.  

# Server Setup

Do these steps on the server that is running Bitfocus Companion. 
  
## Step 1: Server Prerequisites  
Before deploying the watchdog framework on your primary Bitfocus Companion container or host, install the underlying mail transport authentication packages:  
  
```
sudo apt install bsd-mailx postfix libsasl2-modules sasl2-bin -y 
```
*(Select **Internet Site** or **Satellite System** if prompted by the Postfix interactive installation screen).*  

## Step 2: Script Configuration Setup

### Configuration File Layout (config.txt)  
Initialize a configuration file at ~/.config/companion-watchdog/config.txt. The script extracts global variables from the top lines and maps room slots dynamically below.  

```
sudo mkdir -p ~/.config/companion-watchdog/
sudo nano ~/.config/companion-watchdog/
```

Edit this text below to match your system.  
ALERT_EMAIL is the email address that you want to receive updates.  
DELAY_MINUTES is how long you want to wait before an email notification goes out that a Satellite cannot be reconnected.

Next add the Satellites you have. The sample shows three with the room name, IP address, and device hardware serial #.  This is optional, as the watchdog will automatically add any new Satellites via it's auto-discovery code (see Satellite-3 as a sample.)

```
# ==============================================================================
# Bitfocus Companion Watchdog Satellite Inventory Configuration
# Lines starting with '#' or blank rows are safely ignored.
# ==============================================================================
ALERT_EMAIL = XXXXX-your-email-address-XXXXX
DELAY_MINUTES = 15

# Room Name   | Target Client IP | Device Hardware Serial
Satellite-1 | 172.88.88.2 | BLXXXL2B0XX69
Satellite-2 | 172.88.88.3 | AXXXX5421LXX8O
Satellite-3 | 172.88.88.4 | AXXXX5421LXX69  #Automatically added on Fri Jun 26 12:04:09 PM PDT 2026 
```
*Note: Lines containing variables use an = assignment but are distinct because they omit the pipe (|) character, allowing literal equals signs to be used in your room names safely.*  

## Step 3: Install Watchdog Script

### Server Watchdog Script (companion_watchdog.sh)  
Deploy the script file to /root/bin/companion_watchdog.sh and make sure it is executable.

```
sudo mkdir -p /root/bin/companion_watchdog.sh 
```
Now copy the script from github into this file.
  
### Make it executable  
  
```
sudo chmod +x /root/bin/companion_watchdog.sh 
```


## Step 4: Server Postfix Configuration 
To allow the script to send emails, Postfix must route notifications through an authenticated relay.  

**You can skip this step if you already have Postfix working on your Server.**
  
### Open the Postfix configuration targets:   
```
sudo nano /etc/postfix/main.cf 
```
* Verify or append your authenticated SASL parameters to the bottom of the schema map: Plaintext   
```
smtp_sasl_auth_enable = yes

smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd

smtp_sasl_security_options = noanonymous

smtp_tls_security_level = encrypt

header_size_limit = 4096000

relayhost = [XXXX-your-relay-host-name-XXXX]:587

myhostname = XXXX-your-host-name-XXXX

sender_canonical_maps = hash:/etc/postfix/canonical
smtp_tls_note_starttls_offer = yes 
```

### Create Password File  
Set your credentials map (sudo nano /etc/postfix/sasl_passwd):   

```
[XXXX-your-relay-host-name-XXXX]:587 YOUR_SMTP_USERNAME:YOUR_SMTP_PASSWORD 
```

### Create Canonical Map File  
  
Set your canonical map (sudo nano /etc/postfix/canonical):  
  
```
root notifications@XXXX-your-host-name-XXXX
```
  
### Compile the databases and bounce the service:   

```
sudo chmod 600 /etc/postfix/sasl_passwd
sudo chmod 600 /etc/postfix/canonical
sudo postmap /etc/postfix/canonical
sudo postmap /etc/postfix/sasl_passwd
sudo systemctl restart postfix 
```
### Test SMTP  
This should email you a quick message. The results of mailq should be "Mail queue is empty".
  
```
echo "howdy-$RANDOM" | mail -s "test" XXXXX-your-email-address-XXXXX

mailq
```

## Step 5: Automate Script run as a background service

### Systemd Service Automation  
Wrap the watchdog script inside a persistent background service module to allow it to initialize on container boots.  
Generate a configuration unit file:   

```
sudo nano /etc/systemd/system/companion-watchdog.service 
```
Inject the processing parameters:   

```
[Unit]
Description=Bitfocus Companion Satellite Recovery Watchdog
After=companion.service
Requires=companion.service

[Service]
Type=simple
ExecStart=/root/bin/companion_watchdog.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

### Load, enable, and start the service:   
```
 sudo systemctl daemon-reload
sudo systemctl enable companion-watchdog.service
sudo systemctl restart companion-watchdog.service  
```

# Satellite-Side Endpoint Setup  

Each remote satellite environment must be equipped with a lightweight Go-based webhook module that listens on port 9000 to handle out-of-band recovery commands natively.  
  
**Step 1: Install the Webhook Binary Pack**  
  
```
sudo apt install webhook 
```

**Step 2: Establish the Hook Definition Map (sudo nano /etc/webhook/hooks.json)**    

```
sudo nano /etc/webhook.conf
```

Add this text to the file:
  
```
[
  {
    "id": "restart-satellite",
    "execute-command": "/usr/bin/systemctl",
    "command-working-directory": "/tmp",
    "response-message": "watch-dog-remedial-signal-acknowledged",
    "pass-arguments-to-command": [
      {
        "source": "string",
        "name": "restart"
      },
      {
        "source": "string",
        "name": "companion-satellite"
      }
    ]
  }
] 
```

**Step 3: Grant Secure Privileges (Bypass Password Verification Barriers)**  
Add an override rule sheet to permit the webhook application account wrapper to trigger target state manipulation scripts:   
```
sudo systemctl edit webhook.service
```
  
Past this in the top part of the file  
  
```
webhook ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart companion-satellite 
```

**Now do this for sudo**  
  
```
sudo visudo
```
  
**Past this in the bottom of the file**  
  
```
# Ensure Passwordless sudo on Satellites
webhook ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart satellite
```
  
  
**Step 4: Fire Up the Receiver Service**  

Force system configurations reload:

```
sudo systemctl daemon-reload
```

Configure the webhook service manager to initialize on system boot sequences:

```
sudo systemctl enable --now webhook.service
```

Boot the connection interface listener framework up instantly

```
sudo systemctl restart webhook.service
sudo systemctl status webhook.service
```
  
### Run this to test that the web hook works  
  
```
curl -s http://$(ip  -f inet -br  a | grep UP | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'):9000/hooks/restart-satellite
```
