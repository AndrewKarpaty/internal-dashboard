# REPORT

Локальне середовище: k3d v5.9.0 (k3s v1.35.5, вбудований Traefik), Helm v4.2.4.
Файли в `app/` і `frontend/` не змінювались. Змінено: `Dockerfile`, `charts/`, `.github/`.

## Проблеми: симптом → причина → fix

### API образ (`Dockerfile`)

| # | Симптом | Причина | Fix |
|---|---|---|---|
| 1 | API Pod у `CrashLoopBackOff`: `Failed to find attribute 'application' in 'main'` | У `app/main.py` WSGI-об'єкт називається `app`, а CMD запускав `main:application` | `main:app` |
| 2 | Probes/NetworkPolicy/Service не потрапляють у процес | gunicorn слухав `8000`, а чарт (containerPort, probes, NetworkPolicy) очікує `8080` | `--bind 0.0.0.0:8080`, `EXPOSE 8080` |
| 3 | `helm test`: burst 40 запитів / 20 паралельно падає по `--max-time 2`, liveness таймаутить під навантаженням | Дефолтний gunicorn = 1 sync worker, `/api/` спить 0.2 с → запити обробляються послідовно (40 × 0.2 = 8 с) | `--worker-class gthread --workers 2 --threads 8` (16 одночасних запитів; burst ≈ 1–2 с) |
| 4 | gunicorn падає на `readOnlyRootFilesystem: true` | gunicorn пише heartbeat-файли воркерів у tmp-каталог, Python пише `__pycache__` | `--worker-tmp-dir /dev/shm`, `PYTHONDONTWRITEBYTECODE=1`; у чарті додано `emptyDir` (Memory) на `/tmp` |
| 5 | Великий образ, процес під root | `python:3.12` (повний), без `USER` | `python:3.12-slim`, `pip --no-cache-dir`, `USER 10001:10001`; логи gunicorn у stdout |

`APP_ENV` / `REDIS_URL` у Dockerfile не задаються, вони приходять із ConfigMap/Secret.

### Helm-чарт

| # | Симптом | Причина | Fix |
|---|---|---|---|
| 6 | `ErrImagePull` / `ImagePullBackOff` для `internal-dashboard-api:local` і `internal-dashboard-frontend:local` | `pullPolicy: Always` для локальних образів, імпортованих через `k3d image import` (реєстру немає) | `pullPolicy: IfNotPresent` (`values.yaml`) |
| 7 | API падає з `KeyError: 'APP_ENV'` | Deployment передавав змінну `APP_MODE` (ConfigMap key `APP_MODE`), а застосунок читає `APP_ENV` | ConfigMap key і env перейменовано на `APP_ENV`, значення з `values.yaml` (`api.env: prod`) |
| 8 | `CreateContainerConfigError: couldn't find key redis-uri in Secret` | Secret мав ключ `redis-url`, Deployment посилався на `redis-uri` | Ключ у Secret → `redis-uri` |
| 9 | `OOMKilled` у API | `limits.memory: 16Mi` (requests 8Mi), а API з 2 воркерами споживає ≈ 70Mi | requests `96Mi` / limits `128Mi` (в межах LimitRange max 160Mi і ResourceQuota, див. нижче) |
| 10 | API перезапускається, коли Redis недоступний, і отримує трафік до готовності Redis | Probes переплутані: liveness на `/api/ready` (залежить від Redis), readiness на `/api/health`. Крім того `timeoutSeconds: 1`, `failureThreshold: 2`, `periodSeconds: 3` — надто агресивно | liveness → `/api/health` (period 10s, timeout 2s, threshold 3), readiness → `/api/ready` (period 5s, timeout 2s); порт — іменований `http` |
| 11 | Service API без endpoints | Selector `app.kubernetes.io/component: backend`, а Pod має `component: api`; `targetPort: 8000` при containerPort 8080 | Selector через `internal-dashboard.api.selectorLabels`; `targetPort: http` |
| 12 | `/` через Ingress → 502 / connection refused | Service web `targetPort: 8080`, а Caddy слухає `:80` | `targetPort: http` (containerPort 80); порт у Caddyfile береться з `web.containerPort` |
| 13 | `/` → 404 від Caddy | Init-контейнер копіює статику в `/out/dist` (= `/srv/www/dist` у Caddy), а `caddyRoot: /srv/www/build` | `caddyRoot: /srv/www/dist` |
| 14 | `/api/` і `/api/health` → 404 від Flask | Traefik Middleware `stripPrefix /api` відрізав префікс, а Flask-маршрути зареєстровані з `/api/...` | `ingress.stripApiPrefix: false`; Middleware рендериться тільки коли `stripApiPrefix: true` |
| 15 | `/api/` → 503 `"cache":"down"`, readiness API не проходить | NetworkPolicy для Redis дозволяла порт `6380`, Redis слухає `6379` | `networkPolicy.redisIngressPort: 6379` (сама політика лишилась: доступ до Redis тільки з API Pod) |
| 16 | Зміна `web.caddyRoot` / ключів ConfigMap / Secret + `helm upgrade` не перезапускає Pod | ConfigMap монтується через `subPath` / читається як env — Pod не бачить змін без рестарту | Анотації `checksum/config` (+ `checksum/secret` для API) у pod template. ConfigMap розділено на `api-configmap.yaml` і `web-configmap.yaml`, щоб зміна конфігурації одного компонента перезапускала тільки його |
| 17 | Redis і web без probes — `Ready` не відображає реальний стан | Probes відсутні | Redis: readiness `redis-cli ping`, liveness `tcpSocket`. Web: readiness/liveness `httpGet /` |
| 18 | Ризик перевищити ResourceQuota під час rolling update | Під час rollout старий і новий Pod існують одночасно | API: `maxSurge: 1, maxUnavailable: 0` (без простою); Redis: `strategy: Recreate` (single instance, не тримати два Pod). Найгірший випадок (rollout api + web + helm test): limits.memory 128·2 + 128·2 + 64 + 64 = 640Mi ≤ 640Mi, requests.memory 288Mi ≤ 384Mi |
| 19 | API контейнер з повним набором capabilities, root | Немає pod/container securityContext окрім RO FS | Pod `runAsNonRoot: true`, `runAsUser/runAsGroup: 10001`; контейнер `capabilities.drop: [ALL]`. `readOnlyRootFilesystem: true` збережено |

Не змінювались: `LimitRange`, `ResourceQuota`, обидві `NetworkPolicy` (окрім виправлення порту Redis), `resources` усіх контейнерів (API — збільшено), сам smoke-тест.

## CI (`.github/workflows/ci.yml`)

Було: два `docker buildx build` без налаштування buildx, без перевірки чарта.

Стало (на `push` і `pull_request`):
- `permissions: contents: read`, `concurrency` з `cancel-in-progress` по ref.
- Job `images`: matrix (api, frontend), `docker/setup-buildx-action@v3` + `docker/build-push-action@v6` (`push: false`, тег `<image>:<sha>`, GHA cache).
- Job `chart`: `azure/setup-helm@v4` (Helm v3.16.4), `helm lint --strict`, `helm template`.

## Вивід після чистого деплою

Перевірка з хоста через Ingress (Traefik LB на `127.0.0.1:80`). Перед `kubectl get` чекав 190 с після `--wait`.

```text
$ helm upgrade --install dashboard ./charts/internal-dashboard -n dashboard --create-namespace --wait
Release "dashboard" does not exist. Installing it now.
NAME: dashboard
LAST DEPLOYED: Tue Nov 24 15:29:27 2026
NAMESPACE: dashboard
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete

$ kubectl get pods,svc,ingress,endpoints,networkpolicy -n dashboard
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME                                                     READY   STATUS    RESTARTS   AGE
pod/dashboard-internal-dashboard-api-787d79fc46-fw762    1/1     Running   0          3m18s
pod/dashboard-internal-dashboard-redis-877c458f8-5k84w   1/1     Running   0          3m18s
pod/dashboard-internal-dashboard-web-85494488fc-f75wd    1/1     Running   0          3m18s

NAME                                         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/dashboard-internal-dashboard-api     ClusterIP   10.43.194.172   <none>        8000/TCP   3m18s
service/dashboard-internal-dashboard-redis   ClusterIP   10.43.123.210   <none>        6379/TCP   3m18s
service/dashboard-internal-dashboard-web     ClusterIP   10.43.210.10    <none>        80/TCP     3m18s

NAME                                                     CLASS     HOSTS             ADDRESS      PORTS   AGE
ingress.networking.k8s.io/dashboard-internal-dashboard   traefik   dashboard.local   172.19.0.3   80      3m18s

NAME                                           ENDPOINTS         AGE
endpoints/dashboard-internal-dashboard-api     10.42.0.23:8080   3m18s
endpoints/dashboard-internal-dashboard-redis   10.42.0.22:6379   3m18s
endpoints/dashboard-internal-dashboard-web     10.42.0.21:80     3m18s

NAME                                                                 POD-SELECTOR                                                                                                       AGE
networkpolicy.networking.k8s.io/dashboard-internal-dashboard-api     app.kubernetes.io/component=api,app.kubernetes.io/instance=dashboard,app.kubernetes.io/name=internal-dashboard     3m18s
networkpolicy.networking.k8s.io/dashboard-internal-dashboard-redis   app.kubernetes.io/component=redis,app.kubernetes.io/instance=dashboard,app.kubernetes.io/name=internal-dashboard   3m18s

$ curl -i http://dashboard.local/
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 277
Content-Type: text/html; charset=utf-8
Date: Tue, 24 Nov 2026 13:32:45 GMT
Etag: "dn3h6ujjoe5p-7p"
Last-Modified: Tue, 24 Nov 2026 13:29:29 GMT
Server: Caddy
Vary: Accept-Encoding

<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Internal Dashboard</title>
</head>
<body>
  <h1>Internal Dashboard</h1>
  <p>Static frontend served by Caddy.</p>
</body>
</html>

$ curl -i http://dashboard.local/api/
HTTP/1.1 200 OK
Content-Length: 46
Content-Type: application/json
Date: Tue, 24 Nov 2026 13:32:45 GMT
Server: gunicorn

{"cache":"ok","env":"prod","message":"Hello"}

$ curl -i http://dashboard.local/api/health
HTTP/1.1 200 OK
Content-Length: 16
Content-Type: application/json
Date: Tue, 24 Nov 2026 13:32:45 GMT
Server: gunicorn

{"status":"OK"}

$ helm test dashboard -n dashboard
NAME: dashboard
LAST DEPLOYED: Tue Nov 24 15:29:27 2026
NAMESPACE: dashboard
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE:     dashboard-internal-dashboard-smoke
Last Started:   Tue Nov 24 15:32:46 2026
Last Completed: Tue Nov 24 15:32:53 2026
Phase:          Succeeded

POD LOGS: dashboard-internal-dashboard-smoke (curl)
[1/3] Checking /, /api/, /api/health via Ingress...
[2/3] Running concurrency burst (40 requests, 20 parallel)...
Burst finished in 1s (limit: 4s)
[3/3] Verifying API health after burst...
PASS: all smoke and concurrency checks succeeded.


$ kubectl get pods -n dashboard
NAME                                                 READY   STATUS      RESTARTS   AGE
dashboard-internal-dashboard-api-787d79fc46-fw762    1/1     Running     0          3m27s
dashboard-internal-dashboard-redis-877c458f8-5k84w   1/1     Running     0          3m27s
dashboard-internal-dashboard-smoke                   0/1     Completed   0          8s
dashboard-internal-dashboard-web-85494488fc-f75wd    1/1     Running     0          3m27s
```

## Перевірка п.5 (rollout при зміні конфігурації)

`helm upgrade ... --set api.env=staging` → створено новий ReplicaSet API, `/api/` повернув `"env":"staging"`, web і redis не перезапускались.
`helm upgrade ... --set web.caddyRoot=/srv/www/dist/` → новий ReplicaSet web, `/` → 200.

Примітка: Helm 4 при `helm upgrade` без `-f/--set` повторно використовує values попереднього релізу, тому для повернення до дефолтів потрібен `--reset-values`.
