# REPORT

Локальне середовище: k3d v5.9.0 (k3s v1.35.5, вбудований Traefik), Helm v4.2.4.
Файли в `app/` і `frontend/` не змінювались. Змінено: `Dockerfile`, `charts/`, `.github/`.

## Проблеми: симптом → причина → fix

### API образ (`Dockerfile`)

| # | Симптом | Причина | Fix |
|---|---|---|---|
| 1 | API Pod одразу після старту йде в `CrashLoopBackOff`. У логах контейнера gunicorn пише `Failed to find attribute 'application' in 'main'` і завершується. Процес не доходить до прослуховування порту, тому probes навіть не встигають спрацювати. | У `app/main.py` WSGI-об'єкт називається `app`, а CMD запускав `main:application` | `main:app` |
| 2 | Після виправлення імпорту контейнер працює, але Pod ніколи не стає `Ready`: readiness/liveness отримують `connection refused` на 8080, а Service і NetworkPolicy пропускають трафік на порт, де ніхто не слухає. Kubelet перезапускає контейнер по liveness. | gunicorn слухав `8000`, а чарт (containerPort, probes, NetworkPolicy) очікує `8080` | `--bind 0.0.0.0:8080`, `EXPOSE 8080` |
| 3 | `helm test` падає на кроці burst: частина з 40 запитів (20 паралельно) не вкладається в `--max-time 2`. Під час навантаження liveness-probe теж таймаутить, і kubelet може перезапустити API посеред тесту. Поодинокі запити при цьому працюють нормально. | Дефолтний gunicorn = 1 sync worker, `/api/` спить 0.2 с → запити обробляються послідовно (40 × 0.2 = 8 с) | `--worker-class gthread --workers 2 --threads 8` (16 одночасних запитів; burst ≈ 1–2 с), `--timeout 30` |
| 4 | З `readOnlyRootFilesystem: true` gunicorn не може стартувати воркерів і падає з `No usable temporary directory found`. Без RO FS проблема не проявляється, тому її легко пропустити локально в Docker. | gunicorn пише heartbeat-файли воркерів у tmp-каталог, Python пише `__pycache__` | `--worker-tmp-dir /dev/shm`, `PYTHONDONTWRITEBYTECODE=1`; у чарті додано `emptyDir` (Memory) на `/tmp` |
| 5 | Образ важить близько 1 ГБ і довго імпортується в k3d. Процес у контейнері працює від root, що суперечить `runAsNonRoot`. Логи gunicorn буферизуються і з'являються в `kubectl logs` із затримкою. | `python:3.12` (повний), без `USER`, stdout Python буферизований | `python:3.12-slim`, `pip --no-cache-dir`, `PIP_DISABLE_PIP_VERSION_CHECK=1`, `USER 10001:10001`; `PYTHONUNBUFFERED=1`, access/error log gunicorn у stdout |

`APP_ENV` / `REDIS_URL` у Dockerfile не задаються, вони приходять із ConfigMap/Secret.

### Helm-чарт

| # | Симптом | Причина | Fix |
|---|---|---|---|
| 6 | Pod API і init-контейнер web висять у `ErrImagePull` / `ImagePullBackOff` для `internal-dashboard-api:local` і `internal-dashboard-frontend:local`. В events видно, що kubelet намагається тягнути образ з `docker.io`, де такого репозиторію немає. При цьому образ уже є на ноді після `k3d image import`. | `pullPolicy: Always` для локальних образів, імпортованих через `k3d image import` (реєстру немає) | `pullPolicy: IfNotPresent` (`values.yaml`) |
| 7 | API стартує і одразу падає з `KeyError: 'APP_ENV'` у traceback, Pod переходить у `CrashLoopBackOff`. У `kubectl describe pod` видно змінну `APP_MODE`, але застосунок її не читає. | Deployment передавав змінну `APP_MODE` (ConfigMap key `APP_MODE`), а застосунок читає `APP_ENV` | ConfigMap key і env перейменовано на `APP_ENV`, значення з `values.yaml` (`api.env: prod`) |
| 8 | Контейнер API навіть не створюється: Pod у `CreateContainerConfigError`, в events `couldn't find key redis-uri in Secret`. Сам Secret існує, тому помилку видно тільки по назві ключа. | Secret мав ключ `redis-url`, Deployment посилався на `redis-uri` | Ключ у Secret → `redis-uri` |
| 9 | API запускається, але через кілька секунд контейнер вбивається з `OOMKilled` (exit code 137) і цикл повторюється. Під навантаженням burst-тесту це відбувається ще швидше. | `limits.memory: 16Mi` (requests 8Mi), а API з 2 воркерами споживає ≈ 70Mi | requests `96Mi` / limits `128Mi` (в межах LimitRange max 160Mi і ResourceQuota, див. нижче) |
| 10 | Коли Redis недоступний або ще стартує, API Pod перезапускається по liveness, хоча сам процес здоровий. Водночас readiness проходить і Service віддає трафік у Pod, який відповідає 503. Під навантаженням probes з таймаутом 1 с хибно спрацьовують. | Probes переплутані: liveness на `/api/ready` (залежить від Redis), readiness на `/api/health`. Крім того `timeoutSeconds: 1`, `failureThreshold: 2`, `periodSeconds: 3` — надто агресивно | liveness → `/api/health` (period 10s, timeout 2s, threshold 3), readiness → `/api/ready` (period 5s, timeout 2s); порт — іменований `http` |
| 11 | Pod API `Running`/`Ready`, але Service `…-api` не має endpoints, і Ingress на `/api/` віддає 503. `kubectl get endpoints` показує порожній список. | Selector `app.kubernetes.io/component: backend`, а Pod має `component: api`; `targetPort: 8000` при containerPort 8080 | Selector через `internal-dashboard.api.selectorLabels`; `targetPort: http` |
| 12 | `/` через Ingress повертає 502 Bad Gateway. Pod web при цьому `Running`, але Traefik відправляє запити на порт 8080 Pod'а, де ніхто не слухає. | Service web `targetPort: 8080`, а Caddy слухає `:80` | `targetPort: http`; порт у Caddyfile береться з `web.containerPort` (тепер 8080, див. #21) |
| 13 | Після виправлення порту `/` повертає 404 від Caddy (заголовок `Server: Caddy`). Init-контейнер завершується успішно, і файли фізично лежать у volume, але не в тому каталозі, який роздає Caddy. | Init-контейнер копіює статику в `/out/dist` (= `/srv/www/dist` у Caddy), а `caddyRoot: /srv/www/build` | `caddyRoot: /srv/www/dist` |
| 14 | `/api/` і `/api/health` через Ingress повертають 404 у форматі Flask, хоча напряму в Pod (`kubectl port-forward`) ті самі шляхи працюють. Тобто запит доходить до застосунку, але з іншим шляхом. | Traefik Middleware `stripPrefix /api` відрізав префікс, а Flask-маршрути зареєстровані з `/api/...` | `ingress.stripApiPrefix: false`; Middleware рендериться тільки коли `stripApiPrefix: true` |
| 15 | `/api/` повертає 503 з `"cache":"down"`, а `/api/health` — 200. API Pod не проходить readiness (`/api/ready` → 503), хоча Redis Pod `Running` і `Ready`. Ping до Redis з API таймаутить, а не отримує refused. | NetworkPolicy для Redis дозволяла порт `6380`, Redis слухає `6379` | `networkPolicy.redisIngressPort: 6379` (сама політика лишилась: доступ до Redis тільки з API Pod) |
| 16 | Після зміни `web.caddyRoot`, значення ConfigMap або Secret і `helm upgrade` реліз має нову ревізію, але Pod'и працюють зі старою конфігурацією. Щоб зміни застосувались, Pod треба видаляти вручну. | ConfigMap монтується через `subPath` / читається як env — Pod не бачить змін без рестарту | Анотації `checksum/config` (+ `checksum/secret` для API) у pod template. ConfigMap розділено на `api-configmap.yaml` і `web-configmap.yaml`, щоб зміна конфігурації одного компонента перезапускала тільки його |
| 17 | Redis і web стають `Ready` одразу після старту контейнера, навіть якщо процес ще не приймає з'єднань або завис. Kubernetes не перезапускає їх при зависанні і може віддавати трафік у непрацюючий Pod. | Probes відсутні | Redis: readiness `redis-cli ping`, liveness `tcpSocket`; Service Redis `targetPort: redis` (іменований порт). Web: readiness/liveness `httpGet /` |
| 18 | Під час `helm upgrade` новий Pod може зависнути в `Pending` / ReplicaSet не створює Pod з помилкою `exceeded quota`. Ризик зростає після збільшення лімітів API і при одночасному запуску `helm test`. | Під час rollout старий і новий Pod існують одночасно | API: `maxSurge: 1, maxUnavailable: 0` (без простою); Redis: `strategy: Recreate` (single instance, не тримати два Pod). Найгірший випадок (rollout api + web + helm test): limits.memory 128·2 + 128·2 + 64 + 64 = 640Mi ≤ 640Mi, requests.memory 288Mi ≤ 384Mi |
| 19 | API контейнер працює з повним набором Linux capabilities і без гарантії non-root. Помилка в застосунку дає атакуючому більше можливостей, ніж потрібно веб-сервісу. | Немає pod/container securityContext окрім RO FS | Pod `runAsNonRoot: true`, `runAsUser/runAsGroup: 10001`; контейнер `capabilities.drop: [ALL]`. `readOnlyRootFilesystem: true` збережено |
| 20 | Під час rollout API кілька запитів до `/api/` падають: опитування кожні 0.25 с дало 1 × 502 і 1 таймаут із 80 запитів. Збій збігається з моментом, коли старий Pod переходить у `Terminating`. Тобто `maxUnavailable: 0` сам по собі не гарантує rollout без простою. | SIGTERM приходить у gunicorn одночасно з видаленням endpoint. Traefik ще кілька секунд відправляє запити на Pod, який уже закрив сокет | `lifecycle.preStop: sleep 5` (`api.preStopSleepSeconds`), `terminationGracePeriodSeconds: 30`. Після цього 100/100 запитів під час rollout API — 200 |
| 21 | Caddy, init-контейнер frontend і Redis працюють від root із повним набором capabilities і записуваною кореневою FS. Усі Pod'и отримують токен ServiceAccount, хоча жоден не звертається до Kubernetes API. | `securityContext` був налаштований тільки для контейнера API | Спільні хелпери `podSecurityContext` / `containerSecurityContext`: `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]` для всіх контейнерів. Web: uid 10001, Caddy слухає `8080` (непривілейований порт), `emptyDir` на `/data`, `/config`; init-контейнер з `HOME=/tmp` на `emptyDir`. Redis: uid 999, `emptyDir` на `/data` |
| 22 | Web Pod приймав з'єднання від будь-якого Pod'а в кластері. Будь-який новий Pod релізу без своєї NetworkPolicy теж був би відкритий. | NetworkPolicy існували тільки для API і Redis, default-deny не було | `…-default-deny` (Ingress) на всі Pod'и релізу (селектор `name` + `instance`, щоб не зачепити інші застосунки в namespace) і `…-web`: тільки з namespace Traefik на `web.containerPort`. Перевірено: тестовий Pod у namespace отримує відмову на web і API |
| 23 | Redis з лімітом 64Mi без `maxmemory`: при заповненні кешу контейнер отримає `OOMKilled` і втратить усі дані, замість того щоб витіснити старі ключі. Доступ до Redis без пароля, за RDB-снапшоти відповідає дефолтний `save`. | Redis запускався з дефолтною конфігурацією | `--maxmemory 48mb --maxmemory-policy allkeys-lru`, `--save "" --appendonly no` (це кеш). `--requirepass` з ключа Secret `redis-password`, пароль у `redis-uri` для API, probe через `REDISCLI_AUTH`. Пароль генерується один раз (`lookup` існуючого Secret, інакше `randAlphaNum 32`) або задається через `redis.password`; повторний `helm upgrade` не перезапускає Pod'и. `checksum/secret` додано в Pod Redis |
| 24 | Після кожного `helm upgrade` у namespace лишаються старі ReplicaSet (до 10 на Deployment за замовчуванням). `kubectl get rs` швидко стає нечитабельним. | `revisionHistoryLimit` не заданий | `revisionHistoryLimit: 3` для всіх Deployment |

Не змінювались: `LimitRange`, `ResourceQuota`, існуючі `NetworkPolicy` API і Redis (окрім виправлення порту Redis; додано default-deny і web), `resources` усіх контейнерів (API — збільшено), сам smoke-тест.

## CI (`.github/workflows/ci.yml`)

Було: два `docker buildx build` без налаштування buildx, без перевірки чарта.

Стало (на `push` і `pull_request`):
- `permissions: contents: read`, `concurrency` з `cancel-in-progress` по ref.
- Job `images`: matrix (api, frontend), `docker/setup-buildx-action@v3` + `docker/build-push-action@v6` (`push: false`, тег `<image>:<sha>`, GHA cache).
- Job `chart`: `azure/setup-helm@v4` (Helm v3.16.4), `helm lint --strict`, `helm template`.

## Вивід після чистого деплою

Перевірка з хоста через Ingress (Traefik LB на `127.0.0.1:80`).

```text
$ helm upgrade --install dashboard ./charts/internal-dashboard -n dashboard --create-namespace --wait
Release "dashboard" does not exist. Installing it now.
NAME: dashboard
LAST DEPLOYED: Tue Nov 24 16:11:43 2026
NAMESPACE: dashboard
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete

$ kubectl get pods,svc,ingress,endpoints,networkpolicy -n dashboard
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME                                                      READY   STATUS    RESTARTS   AGE
pod/dashboard-internal-dashboard-api-75454fc67d-hj7dd     1/1     Running   0          9s
pod/dashboard-internal-dashboard-redis-86f78b6c97-kwlsn   1/1     Running   0          9s
pod/dashboard-internal-dashboard-web-bb554c55-cntzg       1/1     Running   0          9s

NAME                                         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/dashboard-internal-dashboard-api     ClusterIP   10.43.125.126   <none>        8000/TCP   9s
service/dashboard-internal-dashboard-redis   ClusterIP   10.43.25.122    <none>        6379/TCP   9s
service/dashboard-internal-dashboard-web     ClusterIP   10.43.100.71    <none>        80/TCP     9s

NAME                                                     CLASS     HOSTS             ADDRESS      PORTS   AGE
ingress.networking.k8s.io/dashboard-internal-dashboard   traefik   dashboard.local   172.19.0.3   80      9s

NAME                                           ENDPOINTS         AGE
endpoints/dashboard-internal-dashboard-api     10.42.0.54:8080   9s
endpoints/dashboard-internal-dashboard-redis   10.42.0.52:6379   9s
endpoints/dashboard-internal-dashboard-web     10.42.0.53:8080   9s

NAME                                                                        POD-SELECTOR                                                                                                       AGE
networkpolicy.networking.k8s.io/dashboard-internal-dashboard-api            app.kubernetes.io/component=api,app.kubernetes.io/instance=dashboard,app.kubernetes.io/name=internal-dashboard     9s
networkpolicy.networking.k8s.io/dashboard-internal-dashboard-default-deny   app.kubernetes.io/instance=dashboard,app.kubernetes.io/name=internal-dashboard                                     9s
networkpolicy.networking.k8s.io/dashboard-internal-dashboard-redis          app.kubernetes.io/component=redis,app.kubernetes.io/instance=dashboard,app.kubernetes.io/name=internal-dashboard   9s
networkpolicy.networking.k8s.io/dashboard-internal-dashboard-web            app.kubernetes.io/component=web,app.kubernetes.io/instance=dashboard,app.kubernetes.io/name=internal-dashboard     9s

$ curl -i http://dashboard.local/
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 277
Content-Type: text/html; charset=utf-8
Date: Tue, 24 Nov 2026 14:11:52 GMT
Etag: "dn3i37unq4ry-7p"
Last-Modified: Tue, 24 Nov 2026 14:11:46 GMT
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
Date: Tue, 24 Nov 2026 14:11:52 GMT
Server: gunicorn

{"cache":"ok","env":"prod","message":"Hello"}

$ curl -i http://dashboard.local/api/health
HTTP/1.1 200 OK
Content-Length: 16
Content-Type: application/json
Date: Tue, 24 Nov 2026 14:11:52 GMT
Server: gunicorn

{"status":"OK"}

$ helm test dashboard -n dashboard
NAME: dashboard
LAST DEPLOYED: Tue Nov 24 16:11:43 2026
NAMESPACE: dashboard
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
TEST SUITE:     dashboard-internal-dashboard-smoke
Last Started:   Tue Nov 24 16:11:52 2026
Last Completed: Tue Nov 24 16:11:59 2026
Phase:          Succeeded

$ kubectl get pods -n dashboard
NAME                                                  READY   STATUS      RESTARTS   AGE
dashboard-internal-dashboard-api-75454fc67d-hj7dd     1/1     Running     0          17s
dashboard-internal-dashboard-redis-86f78b6c97-kwlsn   1/1     Running     0          17s
dashboard-internal-dashboard-smoke                    0/1     Completed   0          8s
dashboard-internal-dashboard-web-bb554c55-cntzg       1/1     Running     0          17s
```

## Перевірка п.5 (rollout при зміні конфігурації)

Стартовий стан — щойно встановлений реліз на дефолтних values. Далі по черзі змінюється конфігурація API, потім web, і після кожного кроку перевіряються ReplicaSet, Pod'и та checksum-анотації. Паралельно з кожним `helm upgrade` йшло опитування через Ingress (100 запитів, кожні 0.2 с).

```text
$ kubectl get pods -n dashboard
NAME                                                  READY   STATUS    RESTARTS   AGE
dashboard-internal-dashboard-api-75454fc67d-hj7dd     1/1     Running   0          27s
dashboard-internal-dashboard-redis-86f78b6c97-kwlsn   1/1     Running   0          27s
dashboard-internal-dashboard-web-bb554c55-cntzg       1/1     Running   0          27s

$ kubectl get deploy -n dashboard -o custom-columns=NAME:.metadata.name,CHECKSUM:.spec.template.metadata.annotations.checksum/config
NAME                                 CHECKSUM
dashboard-internal-dashboard-api     eecf00bf626fcc44757a4ee00e13dd934271655a0d250fce9f3afa27033d34f8
dashboard-internal-dashboard-redis   <none>
dashboard-internal-dashboard-web     7c0a0b0c465d844c47800c32059128216489693af593fcbd9ca6611f532aef1f
```

**Крок 1: зміна конфігурації API** (`api.env=staging`). Змінився тільки checksum API, створено новий ReplicaSet API (`67bf56d555`). ReplicaSet і Pod'и web та redis не змінились. Опитування `/api/` під час rollout: 100 × 200.

```text
$ helm upgrade dashboard ./charts/internal-dashboard -n dashboard --set api.env=staging --wait
Release "dashboard" has been upgraded. Happy Helming!
NAME: dashboard
LAST DEPLOYED: Tue Nov 24 16:12:11 2026
NAMESPACE: dashboard
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete

$ kubectl get rs -n dashboard
NAME                                            DESIRED   READY
dashboard-internal-dashboard-api-67bf56d555     1         1
dashboard-internal-dashboard-api-75454fc67d     0         <none>
dashboard-internal-dashboard-redis-86f78b6c97   1         1
dashboard-internal-dashboard-web-bb554c55       1         1

$ kubectl get pods -n dashboard
NAME                                                  READY   STATUS    RESTARTS   AGE
dashboard-internal-dashboard-api-67bf56d555-f9mv2     1/1     Running   0          44s
dashboard-internal-dashboard-redis-86f78b6c97-kwlsn   1/1     Running   0          73s
dashboard-internal-dashboard-web-bb554c55-cntzg       1/1     Running   0          73s

$ kubectl get deploy -n dashboard -o custom-columns=NAME:.metadata.name,CHECKSUM:.spec.template.metadata.annotations.checksum/config
NAME                                 CHECKSUM
dashboard-internal-dashboard-api     9f4f5b6db1bef00fc044e347b5ed3254faa648357df59a365f5c56a8240fdf70
dashboard-internal-dashboard-redis   <none>
dashboard-internal-dashboard-web     7c0a0b0c465d844c47800c32059128216489693af593fcbd9ca6611f532aef1f
```

**Крок 2: зміна конфігурації web** (`web.caddyRoot=/srv/www/dist/`). Змінився тільки checksum web, новий ReplicaSet web (`b8dc895cb`). Pod'и API і redis не перезапускались. Опитування `/` під час rollout: 98 × 200, 1 × 502, 1 таймаут: у web немає `preStop`, тому без простою (#20) зараз тільки rollout API.

```text
$ helm upgrade dashboard ./charts/internal-dashboard -n dashboard --set web.caddyRoot=/srv/www/dist/ --wait
Release "dashboard" has been upgraded. Happy Helming!
NAME: dashboard
LAST DEPLOYED: Tue Nov 24 16:12:58 2026
NAMESPACE: dashboard
STATUS: deployed
REVISION: 3
DESCRIPTION: Upgrade complete

$ kubectl get rs -n dashboard
NAME                                            DESIRED   READY
dashboard-internal-dashboard-api-67bf56d555     1         1
dashboard-internal-dashboard-api-75454fc67d     0         <none>
dashboard-internal-dashboard-redis-86f78b6c97   1         1
dashboard-internal-dashboard-web-b8dc895cb      1         1
dashboard-internal-dashboard-web-bb554c55       0         <none>

$ kubectl get pods -n dashboard
NAME                                                  READY   STATUS    RESTARTS   AGE
dashboard-internal-dashboard-api-67bf56d555-f9mv2     1/1     Running   0          71s
dashboard-internal-dashboard-redis-86f78b6c97-kwlsn   1/1     Running   0          100s
dashboard-internal-dashboard-web-b8dc895cb-br5qd      1/1     Running   0          25s

$ kubectl get deploy -n dashboard -o custom-columns=NAME:.metadata.name,CHECKSUM:.spec.template.metadata.annotations.checksum/config
NAME                                 CHECKSUM
dashboard-internal-dashboard-api     9f4f5b6db1bef00fc044e347b5ed3254faa648357df59a365f5c56a8240fdf70
dashboard-internal-dashboard-redis   <none>
dashboard-internal-dashboard-web     b483335900cf3016e15465d0191614b68737c978ea522da09b74278aeaa79b47

$ kubectl get cm dashboard-internal-dashboard-web -n dashboard -o jsonpath='{.data.Caddyfile}'
:8080 {
    root * /srv/www/dist/
    file_server
}
```

**Результат через Ingress:** `/` віддає статику з нового `caddyRoot`, `/api/` повертає `"env":"staging"`.

```text
$ curl -i http://dashboard.local/
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: 277
Content-Type: text/html; charset=utf-8
Date: Tue, 24 Nov 2026 14:13:23 GMT
Etag: "dn3i46pwqx05-7p"
Last-Modified: Tue, 24 Nov 2026 14:13:02 GMT
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
Content-Length: 49
Content-Type: application/json
Date: Tue, 24 Nov 2026 14:13:23 GMT
Server: gunicorn

{"cache":"ok","env":"staging","message":"Hello"}
```
