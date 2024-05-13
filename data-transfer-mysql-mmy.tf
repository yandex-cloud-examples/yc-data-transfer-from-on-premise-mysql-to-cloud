# Infrastructure for the Yandex Cloud Managed Service for MySQL cluster and Data Transfer
#
# RU: https://yandex.cloud/ru/docs/managed-mysql/tutorials/data-migration
# EN: https://yandex.cloud/en/docs/managed-mysql/tutorials/data-migration
#
# Configure the parameters of the source and target clusters
locals {
  # Source cluster settings:
  source_user    = ""   # Source cluster username
  source_db_name = ""   # Source cluster database name
  source_pwd     = ""   # Source cluster password
  source_host    = ""   # IP address or FQDN of the master host in the source cluster
  source_port    = 3306 # Source cluster port number that Data Transfer will use for connections

  # Target cluster settings:
  target_mysql_version = "" # MySQL version. It must be the same or higher than the version in the source cluster.
  target_sql_mode      = "" # MySQL SQL mode. It must be the same as in the source cluster.
  target_db_name       = "" # Target cluster database name
  target_user          = "" # Target cluster username
  target_password      = "" # Target cluster password

  # The following settings are predefined. Change them only if necessary.
  network_name               = "network"                                        # Name of the network
  subnet_name                = "subnet-a"                                       # Name of the subnet
  zone_a_v4_cidr_blocks      = "10.1.0.0/16"                                    # CIDR block for subnet in the ru-central1-a availability zone
  target_cluster_name        = "mysql-cluster"                                  # Name of the Managed Service for MySQL cluster
  mysql_source_endpoint_name = "mysql-source"                                   # Name of the source endpoint for the MySQL cluster
  mmy_target_endpoint_name   = "managed-mysql-target"                           # Name of the target endpoint for the Managed Service for MySQL cluster
  transfer_name              = "transfer-from-onpremise-mysql-to-managed-mysql" # Name of the transfer from MySQL cluster to the Managed Service for MySQL cluster
}

# Network infrastructure

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for MySQL cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "security-group" {
  description = "Security group for the Managed Service for MySQL cluster"
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allow connections to the cluster from the Internet"
    protocol       = "TCP"
    port           = local.source_port
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Infrastructure for the Managed Service for MySQL cluster

resource "yandex_mdb_mysql_cluster" "mysql-cluster" {
  description        = "Managed Service for MySQL cluster"
  name               = local.target_cluster_name
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  version            = local.target_mysql_version
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  resources {
    resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
    disk_type_id       = "network-hdd"
    disk_size          = 10 # GB
  }

  mysql_config = {
    sql_mode = local.target_sql_mode
  }

  host {
    zone      = "ru-central1-a"
    subnet_id = yandex_vpc_subnet.subnet-a.id
  }
}

# Database of the Managed Service for MySQL cluster
resource "yandex_mdb_mysql_database" "mysql-db" {
  cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
  name       = local.target_db_name
}

# User of the Managed Service for MySQL cluster
resource "yandex_mdb_mysql_user" "mysql-user" {
  cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
  name       = local.target_user
  password   = local.target_password
  permission {
    database_name = yandex_mdb_mysql_database.mysql-db.name
    roles         = ["ALL"]
  }
  depends_on = [
    yandex_mdb_mysql_database.mysql-db
  ]
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "mysql-source" {
  description = "Source endpoint for the MySQL cluster"
  name        = local.mysql_source_endpoint_name
  settings {
    mysql_source {
      connection {
        on_premise {
          hosts = [local.source_host]
          port  = local.source_port
        }
      }
      database = local.source_db_name
      user     = local.source_user
      password {
        raw = local.source_pwd
      }
    }
  }
}

resource "yandex_datatransfer_endpoint" "managed-mysql-target" {
  description = "Target endpoint for the Managed Service for MySQL cluster"
  name        = local.mmy_target_endpoint_name
  settings {
    mysql_target {
      connection {
        mdb_cluster_id = yandex_mdb_mysql_cluster.mysql-cluster.id
      }
      database = yandex_mdb_mysql_database.mysql-db.name
      user     = yandex_mdb_mysql_user.mysql-user.name
      password {
        raw = local.target_password
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "mysql-transfer" {
  description = "Transfer from the MySQL cluster to the Managed Service for MySQL cluster"
  name        = local.transfer_name
  source_id   = yandex_datatransfer_endpoint.mysql-source.id
  target_id   = yandex_datatransfer_endpoint.managed-mysql-target.id
  type        = "SNAPSHOT_AND_INCREMENT" # Copy all data from the source cluster and start replication
}
