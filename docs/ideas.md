# Ideas de otras librerias

## Tokio

1. Métricas del runtime. Tokio expone por worker: profundidad del queue, tareas corridas, tiempo ocupado versus esperando, profundidad del queue del pool bloqueante. Bearings tiene métricas HTTP. Faltan las del loop: iteraciones, waits de epoll, largo del run queue, ratio ocupado, y para el pool el tiempo de espera en cola. Es lo que te dice si un loop está saturado antes de que el stall detector salte.
2. Elasticidad del pool bloqueante. Tokio crea hilos bajo demanda hasta max_blocking_threads y los retira tras 10 s sin trabajo (thread_keep_alive). Si el pool de bearings es de tamaño fijo, un servidor con picos paga hilos ociosos o cola. Tendría que confirmar en bearings.rt.workers cómo se dimensiona hoy.
3. Slot LIFO. Tokio corre primero la tarea recién despertada, por localidad de caché. En el pool de workers sería: el worker que acaba de terminar un trabajo toma el siguiente del mismo exchange o conexión si hay uno. Ganancia chica y medible solo con benchmark.
4. Introspección tipo tokio-console. Volcado del estado de cada loop y conexión al recibir una señal. Bearings tiene el stall detector en builds -dWD_STALL; una versión de producción, bajo demanda, sería útil para diagnosticar sin reconstruir.


## NGINX y Envoy

1. Rebalanceo después del accept. Envoy tiene un "exact connection balancer": el
loop que acepta pasa el socket al loop con menos conexiones. Eso ataca
directamente un riesgo que docs/design.md sección 11 ya lista: SO_REUSEPORT
reparte por hash, no por carga. Seastar hace lo contrario con
SO_ATTACH_REUSEPORT_CBPF: un filtro que manda cada conexión al loop de la CPU
donde llegó la interrupción de red, lo que además mantiene la localidad de
caché. El filtro son unas líneas de BPF clásico; el rebalanceo es un TLoop.Post
con el fd.
2. Overload manager (Envoy). Cuando la memoria o la CPU pasan un umbral, deja de
aceptar, cierra conexiones ociosas o responde 503 antes de hacer trabajo.
bearings tiene el tope de conexiones y el 503 por saturación del pool; falta el
disparador por recursos. Más grande.


## uWebSockets

1. maxBackpressure con cierre. Hoy un cliente que no lee frena la lectura y el
envío devuelve wsFull. µWS deja además configurar "cerrar al pasar el límite",
útil para broadcast donde un cliente lento no debe retener memoria.


## Go net/http

1. Deadlines por request desde el handler (ResponseController.SetWriteDeadline) y
tope de body por ruta (MaxBytesReader). Si bearings ya tiene tope de body y
timeout de escritura globales, lo que faltaría es poder ajustarlos por request.
Tendría que confirmar qué hay en TH1Config.
