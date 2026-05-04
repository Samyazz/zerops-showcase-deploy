project:
  name: ${PROJECT_NAME}
  corePackage: ${CORE_PACKAGE}

services:
  - hostname: app
    type: ${APP_TYPE}
    enableSubdomainAccess: true
    envSecrets:
      CORE_MODE: ${APP_CORE_MODE}
    minContainers: ${APP_MIN_CONTAINERS}
    maxContainers: ${APP_MAX_CONTAINERS}
    verticalAutoscaling:
      cpuMode: ${APP_CPU_MODE}
      minRam: ${APP_MIN_RAM}
      minFreeRamGB: ${APP_MIN_FREE_RAM}

  - hostname: worker
    type: ${WORKER_TYPE}
    minContainers: ${WORKER_MIN_CONTAINERS}
    maxContainers: ${WORKER_MAX_CONTAINERS}
    verticalAutoscaling:
      cpuMode: ${WORKER_CPU_MODE}
      minRam: ${WORKER_MIN_RAM}
      minFreeRamGB: ${WORKER_MIN_FREE_RAM}

  - hostname: db
    type: ${DB_TYPE}
    mode: ${DB_MODE}
    priority: 10
    verticalAutoscaling:
      cpuMode: ${DB_CPU_MODE}
      minRam: ${DB_MIN_RAM}
      minFreeRamGB: ${DB_MIN_FREE_RAM}

  - hostname: redis
    type: ${REDIS_TYPE}
    mode: ${REDIS_MODE}
    priority: 10

  - hostname: queue
    type: ${QUEUE_TYPE}
    mode: ${QUEUE_MODE}
    priority: 10

  - hostname: storage
    type: object-storage
    objectStorageSize: ${STORAGE_SIZE}
    objectStoragePolicy: ${STORAGE_POLICY}
    priority: 10
