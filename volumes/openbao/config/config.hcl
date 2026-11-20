# OpenBao Server Configuration
# Raft integrated storage for persistent secrets across container restarts
# (the file backend was removed in OpenBao 2.7)

storage "raft" {
  path    = "/openbao/data"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr      = "http://0.0.0.0:8200"
cluster_addr  = "http://127.0.0.1:8201"
ui            = true
disable_mlock = true
