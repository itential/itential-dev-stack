# OpenBao Server Configuration
# File-based storage for persistent secrets across container restarts

storage "file" {
  path = "/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr      = "http://0.0.0.0:8200"
ui            = true
disable_mlock = true
