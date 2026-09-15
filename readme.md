# Distributed Intelligence Lab website

Website of the Gdańsk Tech [Distributed Intelligence Lab](http://dil.eti.pg.edu.pl)

## Docker image

Serves this repository's `main` branch with nginx and checks for updates roughly every five minutes.

```sh
docker compose up
```

Open [localhost:8080](http://localhost:8080).

To change the polling interval (default: `300` seconds):

```sh
export POLL_INTERVAL_SECONDS=600
docker compose up -d
```

Docker image is published to [PG GitLab](https://git.pg.edu.pl/p966564/overfittedminds-docker-image/container_registry)
