# HTTP server
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root {{PROJECT_DIR}}/www;
    index index.html;

    # iOS captive portal detection
    location = /hotspot-detect.html {
        default_type text/html;
        add_header X-Redirect-Reason "Captive Portal";
        try_files /index.html =404;
    }

    # Android connectivity check
    location = /generate_204 {
        return 204;
    }

    # Windows connectivity check
    location = /connecttest.txt {
        return 200 "Success\r\n";
    }

    # Microsoft NCSI
    location = /ncsi.txt {
        return 200 "Microsoft NCSI";
    }

    # Static files
    location / {
        try_files $uri $uri/ =404;
    }

    # API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}

# HTTPS server
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;

    ssl_certificate {{SSL_CERT}};
    ssl_certificate_key {{SSL_KEY}};

    root {{PROJECT_DIR}}/www;
    index index.html;

    location = /hotspot-detect.html {
        default_type text/html;
        try_files /index.html =404;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}