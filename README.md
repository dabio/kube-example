# Getting Started with Kubernetes

This will give you a quick intro into [kubernetes][kube] and some of its components.

## Prerequisites

You'll need to have a few tools installed for this guide:

* [Go][go]
* [AWS Command Line Interface][aws-cli] and an AWS account
* [Kubernetes CLI][kube-cli]
* [Docker][docker]

I'll also assume that you have a [kubernetes installation][kube-installation] running.

We'll use a simple [Go][go] application as an example (main.go):

```go
package main

import (
    "fmt"
    "log"
    "net/http"
)

func index(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintln(w, "Ahoi")
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/", index)

    s := &http.Server{
        Addr:    ":8080",
        Handler: mux,
    }

    log.Fatal(s.ListenAndServe())
}
```

Run this application with `go run main.go` and open your browser at [localhost:8080][localhost]. You'll have our example application greeting you.

Let's get Docker up and running for this app. Use this `Dockerfile`:

```dockerfile
FROM scratch
COPY server /
ENTRYPOINT ["/server"]
EXPOSE 8080
```

Build and start the docker container:

```bash
$ go build -o server -v .
$ docker build -t test-go .
$ docker run -p 8080:8080 -d test-go
```

_If you run the commands on macOS, you'll get the docker error "System error: exec format error". That means, the binary is in a macOS format. We need a linux format. Replace the first line with this command:_

```bash
$ CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o server -v .
```

Now open your browser again. You'll see the same message, but this time running on a docker container.

If you don't know the address your docker container is running, call `docker ps` and use the printed address.

```bash
$ docker ps
CONTAINER ID  IMAGE    COMMAND    CREATED             STATUS              PORTS
84631e65ccf9  test-go  "/server"  About a minute ago  Up About a minute   192.168.64.7:8080->8080/tcp
```

You can stop the container with `docker stop 84631e65ccf9`.

Tag your image and and push it to your [AWS EC2 Container Registry][aws-ecr]:

```bash
$ docker tag test-go [account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v1
$ aws ecr get-login --no-include-email | sh -
Login Succeeded
$ docker push [account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v1
```

Mind the _v1_ tag that we specified here. We will use this tag for versioning the image.

## Enter the Kube

### Pods

A pod is a group of one or more containers (eg. Docker containers) that share storage and network.

This is a specification for our container `kube/pod.yml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-go
  labels:
    app: hello-go
spec:
  imagePullSecrets:
    - name: aws-ecr-hello-go
  containers:
    - name: hello-go
      image: [account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v1
      ports:
        - containerPort: 8080
```

This is a basic pod file, ignore the `imagePullSecrets` part for now, we come to that later on. The specification contains the name, and which container it consist of. We use only one container here, the one pushed to AWS ECR before with the given port `8080`.

Start the pod and see it running.

```bash
$ kubectl create -f kube/pod.yml
pod "hello-go" created
$ kubectl get pods
NAME       READY   STATUS         RESTARTS   AGE
hello-go   0/1     ErrImagePull   0          35s
```

You can get in detail information about your pod with the `describe` command. `describe` and `get ` will give you all the information about your running components you'll need.

```bash
$ kubectl describe pod hello-go
Name:         hello-go
Namespace:    default
Node:         …
…
```

You see, that the pod is not running as you want. The messages _ErrImagePull_ appears in the lines. That's because we don't have the credentials to let our kubernetes instance pull the image from AWS ECR. That's where the line `imagePullSecrets` in the _pod.yml_ file comes in.

### Secrets

We need a secret that allows the image download. If you haven't done already, login to AWS ECR with this command:

```bash
$ aws ecr get-login --no-include-email | sh -
Login Succeeded
```

This creates an authentication file for docker in `~/.docker/config.json` which we need to paste into a kubernetes secret file:

```bash
$ printf "%s\n" \
    "apiVersion: v1" \
    "kind: Secret" \
    "metadata:" \
    "  name: aws-ecr-hello-go" \
    "type: kubernetes.io/dockerconfigjson" \
    "data:" \
    "  .dockerconfigjson: $(cat ~/.docker/config.json | base64 | tr -d '\n')" \
    > kube/secret.yml
```

Add the generated file to your kubernetes instance:

```bash
$ kubectl create -f kube/secret.yml
secret "aws-ecr-hello-go" created
$ kubectl get secrets
NAME               TYPE                             DATA   AGE
aws-ecr-hello-go   kubernetes.io/dockerconfigjson   1      22s
```

Now run `kubectl get pods` again and you'll see the pods should be created by now.

### Services

The pod is running, but not accessible from the outside. That's the job for a service. Services define a set of pods and policies to access them.

We use this specification for our example (`kube/service.yml`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-go
spec:
  type: NodePort
  ports:
  - port: 8080
  selector:
    app: hello-go
```

Same as for the [pod file][this-pod] a _name_ and a _spec_ are required. The spec targets our pod with the label `hello-go` on port `8080`.

Make the file known to kubernetes:

```bash
$ kubectl create -f kube/service.yml
service "hello-go" created
$ kubectl get services
NAME       TYPE       CLUSTER-IP   EXTERNAL-IP   PORT(S)          AGE
hello-go   NodePort   10.3.0.60    <none>        8080:32734/TCP   15s
```

We have a service running. Mind the port 32734, we can call our app via the IP address of your kubernetes and the given port.
If you do not know the IP address, get it with this call:

```bash
$ kubectl describe pod hello-go
Name:         hello-go
Namespace:    default
Node:         10.10.1.43/10.10.1.43
…
```

Open [10.10.1.43:32734][ip].

### Deployments

Deployments describe _desired states_ for Pods. Deployment controllers updates pods to that state.

Example (`kube/deployment.yml`):

```yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: hello-go
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: hello-go
    spec:
      imagePullSecrets:
        - name: aws-ecr-hello-go
      containers:
        - name: hello-go
          image: [account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v1
          ports:
            - containerPort: 8080
```

This is similar to a [pod spec][this-pod]. _Replicas_ and _strategy_ are new keywords. _Replicas_ allows the definition of the number of pods (horizontal scaling). The _strategy_ specifies the method used to replace old pods. The _type_ can be _Recreate_ or _RollingUpdate_ (default).

With defined deployments, we do not need the pods here<sup>[1](#pod-not-needed)</sup> anymore.

```bash
$ kubectl delete pod hello-go
pod "hello-go" deleted
$ kubectl create -f kube/deployment.yml
deployment "hello-go" created
$ kubectl get pods
NAME                        READY   STATUS    RESTARTS   AGE
hello-go-1587988212-rs02n   1/1     Running   0          15s
```

You see the pod got a random name from our deployment now. We can still call it within our browser [10.10.1.43:32734][ip]:

#### Scaling

With our deployment, we can scale the number of pods horizontally.

```bash
$ kubectl scale deploy hello-go --replicas=3
deployment "hello-go" scaled
$ kubectl get pods
NAME                        READY   STATUS    RESTARTS   AGE
hello-go-1587988212-pc0c2   1/1     Running   0          1s
hello-go-1587988212-rs02n   1/1     Running   0          4m
hello-go-1587988212-tfmzh   1/1     Running   0          1s
```

#### RollingUpdate

Lets modify our app a bit and add a new endpoint:

```go
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func index(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintln(w, "Ahoi")
}

func hostname(w http.ResponseWriter, r *http.Request) {
  name, err := os.Hostname()
  if err != nil {
    fmt.Fprintln(w, "cannot get hostname")
  }

  fmt.Fprintln(w, "Host: "+name)
}

func main() {
    mux := http.NewServeMux()
    mux.HandleFunc("/", index)
    mux.HandleFunc("/hostname", hostname)

    s := &http.Server{
        Addr:    ":8080",
        Handler: mux,
    }

    log.Fatal(s.ListenAndServe())
}
```

Now build it, tag it and push version _v2_ to ECR.

```bash
$ go build -o server -v .
$ docker build -t test-go .
$ docker tag test-go [account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v2
$ docker push [account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v2
```

Mind the label _v2_ for our second version for the tags.

Now that we have our _v2_ on ECR, we can easily switch to it:

```bash
$ kubectl set image deploy/hello-go hello-go=[account-id].dkr.ecr.[region-id].amazonaws.com/test/test-go:v2
deployment "hello-go" image updated
$ kubectl get pods
NAME                        READY   STATUS              RESTARTS   AGE
hello-go-1587988212-pc0c2   0/1     Terminating         0          14m
hello-go-1587988212-rs02n   1/1     Running             0          18m
hello-go-1587988212-tfmzh   1/1     Terminating         0          14m
hello-go-3469790515-g1gdm   0/1     ContainerCreating   0          0s
hello-go-3469790515-h70dw   0/1     ContainerCreating   0          0s
hello-go-3469790515-l5rbj   1/1     Running             0          0s
```

You can see newer pods are generated in parallel with our _RollingUpdate_. The app will always be online with this strategy.

_Do not forget to add the newer tag to the specs in `kube/deployment.yml`. You can apply those changes as well:_

```bash
$ kubectl apply -f kube/deployment.yml
deployment "hello-go" configured
```

Visit your app in your browser and browse to the new endpoint [10.10.1.43:32734/hostname][ip-hostname]. You will see the current name of the pod as a hostname.

#### Autoscaling

With Horizontal Pod Autoscaling (HPA), kubernetes automatically scales the number of pods in a deployment on a specific metric (eg CPU utilization).

Scale your pods down to one.

```bash
$ kubectl scale deploy hello-go --replicas=1
deployment "hello-go" scaled
```

Now update your `kube/deployment.yml` and set resource limits for your container.

```yaml
…
    containers:
      - name: hello-go
        image: …
        ports:
          - containerPort: 8080
        resources:
          limits:
            cpu: 200m
          requests:
            cpu: 150m
…
```

Those numbers are in millicores (1/1000 of one cpu core). If you have a node with 4 cores, the CPU capacity will be `4 x 1000m = 4000m`. _Request_ is a soft limit, that the container have a strong guarantee of availability. _Limit_ describes the hard limit, the pod will not exceed.


Get the capacity of your nodes with the following commands:

```bash
$ kubectl get nodes
NAME         STATUS   ROLES    AGE   VERSION
10.10.1.43   Ready    <none>   35d   v1.7.3+coreos.0
10.10.1.45   Ready    <none>   35d   v1.7.3+coreos.0
$ kubectl describe nodes 10.10.1.43
Name:               10.10.1.43
…
Capacity:
 cpu:     8
 memory:  32951388Ki
 pods:    110
…
```

This machine is pretty beefy with its 8 cores.

Update your deployment with the given capacities and apply it to your running instance.

```bash
$ kubectl apply -f kube/deployment.yml
deployment "hello-go" configured
$ kubectl get pods
NAME                        READY   STATUS    RESTARTS   AGE
hello-go-3469790515-l5rbj   1/1     Running   0          22h
$ kubectl describe pod hello-go-3469790515-l5rbj
Name:           hello-go-3469790515-l5rbj
…
    Limits:
      cpu:  200m
    Requests:
      cpu:        150m
…
```

Lets run a load test:

```bash
$ wrk -t12 -c100 -d60s "http://10.10.1.43:32734/hostname"
```

And open a terminal besides the one running the test.

```bash
$ kubectl top pod hello-go-3469790515-l5rbj
NAME                        CPU(cores)   MEMORY(bytes)
hello-go-3469790515-l5rbj   45m          7Mi
```

You see, we won't reach our limit. Lower it to `10m` and rund the test again. The CPU won't get over our defined threshold.

Now scale your deployment and run the test again.

```bash
$ kubectl autoscale deploy hello-go --min=1 --max=5 --cpu-percent=25
deployment "hello-go" autoscaled
$ wrk -t12 -c100 -d60s "http://10.10.1.43:32734/hostname"
```

At one point, you'll see that new pods get created. It takes maximum 30s. This is the default period, the Autoscaler checks the pods for their resource utilization.

```bash
$ kubectl get pods
NAME                        READY   STATUS    RESTARTS   AGE
hello-go-3757189725-2dmc0   1/1     Running   0          6m
hello-go-3757189725-6jwks   1/1     Running   0          19s
hello-go-3757189725-tsx5t   1/1     Running   0          19s
hello-go-3757189725-x1rrm   1/1     Running   0          19s
$ kubectl get hpa
NAME       REFERENCE             TARGETS    MINPODS   MAXPODS   REPLICAS   AGE
hello-go   Deployment/hello-go   0% / 25%   1         5         1          23m
$ kubectl describe hpa hello-go
Name:     hello-go
…
```

That's how the yaml configration file will look like for our example.


```yaml
apiVersion: autoscaling/v1
kind: HorizontalPodAutoscaler
metadata:
  name: hello-go
spec:
  maxReplicas: 5
  minReplicas: 1
  scaleTargetRef:
    apiVersion: extensions/v1beta1
    kind: Deployment
    name: hello-go
  targetCPUUtilizationPercentage: 25
```

Remove the HPA.

```bash
$ kubectl delete hpa hello-go
horizontalpodautoscaler "hello-go" deleted
```

### Ingress

Ingress is a collection of rules, that allow inbound connections to reach the cluster. It can configured to  give services externally reachable URLs, load balance traffic and offers name based virtual hosting.

This is an example for our application (`kube/ingress.yml`):

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: hello-go-ingress
spec:
  rules:
    - host: hello-go.com
      http:
        paths:
          - backend:
              serviceName: hello-go
              servicePort: 8080
```

We are routing all requests to _hello-go.com_ to our service _hello-go_.

```bash
$ kubectl create -f kube/ingress.yml
ingress "hello-go-ingress" created
$ kubectl get ing
kubectl get ing
NAME               HOSTS          ADDRESS      PORTS   AGE
hello-go-ingress   hello-go.com   10.10.1.45   80      34s
```

Add the host and the IP address to your `/etc/hosts` file and you no longer need to remember the IP and PORT to your service.

Using the Ingress has a lot of advantages. You can specify different services on url basis:

```yaml
  paths:
    - path: /hello
      backend:
      serviceName: hello-go
      servicePort: 8080
    - path: /service
      backend:
      serviceName: different-service
      servicePort: 8080
```

Or configure different hosts for your service:

```yaml
  rules:
    - host: hello-go.com
      http:
        paths:
          - backend:
              serviceName: hello-go
              servicePort: 8080
    - host: example.com
      http:
        paths:
          - backend:
              serviceName: different-service
              servicePort: 8080
```

Or even mix everything.


  <a name="pod-not-needed">1</a>: We don't need the pod definition in our example.

  [kube]: https://kubernetes.io "Production-Grade Container Orchestration"
  [kube-cli]: https://kubernetes.io/docs/tasks/tools/install-kubectl/ "Install and Set Up kubectl"
  [kube-installation]: https://kubernetes.io/docs/setup/pick-right-solution/ "Picking the Right Solution"
  [go]: https://golang.org "The Go Programming Language"
  [aws-cli]: https://aws.amazon.com/de/cli/ "AWS Command Line Interface"
  [aws-ecr]: https://eu-central-1.console.aws.amazon.com/ecs/home?region=eu-central-1#/repositories "Amazon EC2 Container Service"
  [docker]: https://www.docker.com "Build, Ship, and Run Any App, Anywhere"
  [localhost]: http://localhost:8080/
  [this-pod]: #pods
  [ip]: http://10.10.1.43:32734/
  [ip-hostname]: http://10.10.1.43:32734/hostname

