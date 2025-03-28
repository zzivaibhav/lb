#!/bin/bash

# Get external IP address of the machine (macOS compatible)
echo "Detecting MacBook's IP address..."
if [[ "$(uname)" == "Darwin" ]]; then
  # For MacOS, try Wi-Fi first, then Ethernet
  EXTERNAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")
else
  # For Linux
  EXTERNAL_IP=$(hostname -I | awk '{print $1}')
fi

echo "Your laptop's external IP is: $EXTERNAL_IP"

# Build the Docker images locally (no push)
echo "Building Docker images..."
docker build -t handyshare/app1:latest ./app1
docker build -t handyshare/app2:latest ./app2

# Detect Kubernetes environment
KUBE_CONTEXT=$(kubectl config current-context)
echo "Detected Kubernetes context: $KUBE_CONTEXT"

# Install MetalLB if not already installed and if not using minikube
if [[ "$KUBE_CONTEXT" != "minikube" ]]; then
  echo "Checking for MetalLB..."
  if ! kubectl get ns metallb-system &>/dev/null; then
    echo "Installing MetalLB..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
    
    # Wait for MetalLB to be ready
    echo "Waiting for MetalLB to be ready..."
    kubectl wait --namespace metallb-system \
      --for=condition=ready pod \
      --selector=app=metallb \
      --timeout=120s || true
  fi

  # Apply MetalLB configuration
  echo "Configuring MetalLB..."
  kubectl apply -f ./k8s/pool-1.yaml
  kubectl apply -f ./k8s/l2advertisement.yml
fi

# Delete existing ingress controller if it's in a bad state
echo "Checking for existing ingress controller..."
if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q CrashLoop; then
  echo "Found crashed ingress controller, cleaning up..."
  kubectl delete namespace ingress-nginx
  sleep 5
fi

# Deploy Nginx Ingress Controller
echo "Installing Nginx Ingress Controller..."
if [[ "$KUBE_CONTEXT" == "minikube" ]]; then
  # For Minikube, use the minikube addon
  echo "Using Minikube's built-in ingress addon..."
  minikube addons enable ingress
  
  # Wait for the ingress controller to be ready
  echo "Waiting for Minikube Ingress Controller to be ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s || true
else
  # For other environments, use the standard installation
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/baremetal/deploy.yaml
  
  # Wait for the ingress controller to be ready
  echo "Waiting for Ingress Controller to be ready..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s || true
fi

# Apply the Kubernetes manifests
echo "Deploying applications..."
kubectl delete -f ./k8s/app1-deployment.yaml 2>/dev/null || true
kubectl delete -f ./k8s/app2-deployment.yaml 2>/dev/null || true
kubectl delete -f ./k8s/ingress.yaml 2>/dev/null || true

sleep 5

kubectl apply -f ./k8s/app1-deployment.yaml
kubectl apply -f ./k8s/app2-deployment.yaml
kubectl apply -f ./k8s/ingress.yaml

echo "Deployment completed!"

# Get access information based on Kubernetes environment
if [[ "$KUBE_CONTEXT" == "minikube" ]]; then
  echo "You're using Minikube. Using Minikube tunnel to access services..."
  echo "In a separate terminal, run: minikube tunnel"
  echo "You can access applications at:"
  echo "- App1 at: http://$(minikube ip)/app1"
  echo "- App2 at: http://$(minikube ip)/app2"
  echo ""
  echo "Or you can use NodePort access:"
  NODE_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
  if [ -n "$NODE_PORT" ]; then
    echo "- App1 at: http://$(minikube ip):$NODE_PORT/app1"
    echo "- App2 at: http://$(minikube ip):$NODE_PORT/app2"
  fi
else
  # For non-Minikube environments, try to get LoadBalancer IP
  INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  
  if [ -n "$INGRESS_IP" ] && [ "$INGRESS_IP" != "none" ]; then
    echo "LoadBalancer IP assigned: $INGRESS_IP"
    echo "You can access applications at:"
    echo "- App1 at: http://$INGRESS_IP/app1"
    echo "- App2 at: http://$INGRESS_IP/app2"
  else
    echo "No LoadBalancer IP assigned. Using NodePort access method instead."
    NODE_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$NODE_PORT" ]; then
      echo "You can access applications at:"
      echo "- App1 at: http://$EXTERNAL_IP:$NODE_PORT/app1"
      echo "- App2 at: http://$EXTERNAL_IP:$NODE_PORT/app2"
    else
      echo "Unable to determine access method. Please check your cluster configuration."
    fi
  fi
fi

echo ""
echo "Checking status of services..."
kubectl get svc --all-namespaces | grep -E 'NAMESPACE|ingress-nginx|app'

echo ""
echo "Checking status of ingress..."
kubectl get ingress

echo ""
echo "Checking status of pods..."
kubectl get pods --all-namespaces | grep -E 'NAMESPACE|ingress-nginx|app|metallb'

echo ""
echo "For detailed information on any issues, run:"
echo "kubectl describe pods -n ingress-nginx"
