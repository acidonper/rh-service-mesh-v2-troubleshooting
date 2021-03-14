##
# Script to prepare Openshift Laboratory
##

##
# Users 
##
USERS="pepito
pepita
manolito
manolita
user1
kubernesto"

##
# Adding user to htpasswd
##
htpasswd -c -b users.htpasswd admin password
for i in $USERS
do
  htpasswd -b users.htpasswd $i $i
done

##
# Creating htpasswd file in Openshift
##
oc delete secret lab-users -n openshift-config
oc create secret generic lab-users --from-file=htpasswd=users.htpasswd -n openshift-config

##
# Configuring OAuth to authenticate users via htpasswd
##
cat <<EOF > oauth.yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - htpasswd:
      fileData:
        name: lab-users
    mappingMethod: claim
    name: lab-users
    type: HTPasswd
EOF

cat oauth.yaml | oc apply -f -

##
# Creating a custom role to manage Istio Objects
##
cat <<EOF > admin-mesh-custom-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: admin-mesh
rules:
  - apiGroups:
    - ""
    resources:
    - secrets
    verbs:
    - create
    - get
    - list
    - watch
  - apiGroups:
    - ""
    - route.openshift.io
    resources:
    - routes
    verbs:
    - create
    - delete
    - deletecollection
    - get
    - list
    - patch
    - update
    - watch
  - apiGroups:
    - ""
    - route.openshift.io
    resources:
    - routes/custom-host
    verbs:
    - create
  - apiGroups:
    - ""
    - route.openshift.io
    resources:
    - routes/status
    verbs:
    - get
    - list
    - watch
  - apiGroups:
    - ""
    - route.openshift.io
    resources:
    - routes
    verbs:
    - get
    - list
    - watch
  - apiGroups:
    - maistra.io
    resources:
    - servicemeshmemberrolls
    verbs:
    - get
    - list
    - watch
EOF

cat admin-mesh-custom-role.yaml | oc apply -f -

##
# Creating a custom role to connect to pods
##
cat <<EOF > connect-pods-custom-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: connect-pods
rules:
- apiGroups:
  - ""
  resources:
  - pods/attach
  - pods/exec
  - pods/portforward
  - pods/proxy
  - secrets
  - services/proxy
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - pods/attach
  - pods/exec
  - pods/portforward
  - pods/proxy
  verbs:
  - create
  - delete
  - deletecollection
  - patch
  - update
EOF

cat connect-pods-custom-role.yaml | oc apply -f -

##
# Disable self namespaces provisioner 
##
oc patch clusterrolebinding.rbac self-provisioners -p '{"subjects": null}'

##
# Adding required roles to users
##
for i in $USERS
do
  # Create Namespaces
  oc new-project $i-namespace
  oc new-project $i-namespace-mesh-external

  # Create and apply permission Nginx resources
  oc create sa nginx -n $i-namespace-mesh-external
  oc adm policy add-scc-to-user anyuid -z nginx -n $i-namespace-mesh-external
  
  # Apply permissions in openshift-ingress project
  oc adm policy add-role-to-user view $i -n openshift-ingress
  oc adm policy add-role-to-user connect-pods $i -n openshift-ingress

  # Apply permissions in istio-system project
  oc adm policy add-role-to-user view $i -n istio-system
  oc adm policy add-role-to-user connect-pods $i -n istio-system
  oc adm policy add-role-to-user admin-mesh $i -n istio-system
  oc adm policy add-role-to-user mesh-user $i -n istio-system --role-namespace istio-system

  # Apply permission in their namespaces
  oc adm policy add-role-to-user admin $i -n $i-namespace
  oc adm policy add-role-to-user admin $i -n $i-namespace-mesh-external
done


###
## CHAPTER 6 
###

## Create general service
oc new-project mesh-external
oc create sa nginx -n mesh-external
oc adm policy add-scc-to-user anyuid -z nginx -n mesh-external
oc create -n mesh-external secret tls nginx-server-certs --key certs/nginx.example.com.key.pem --cert certs/nginx.example.com.cert.pem
oc create -n mesh-external secret generic nginx-ca-certs --from-file=certs/ca-chain.cert.pem
oc create configmap nginx-configmap -n mesh-external --from-file=nginx.conf=files/nginx.conf
oc create -f 00-nginx-svc-pod.yml -n mesh-external

## Configure mesh 
oc create -f 01-mesh.yml -n istio-system
oc create -n istio-system secret tls nginx-client-certs --key certs/nginx.example.com.key.pem --cert certs/nginx.example.com.cert.pem
oc create -n istio-system secret generic nginx-ca-certs --from-file=certs/ca-chain.cert.pem

cat <<EOF > gateway-path.json
[{
  "op": "add",
  "path": "/spec/template/spec/containers/0/volumeMounts/0",
  "value": {
    "mountPath": "/etc/istio/nginx-client-certs",
    "name": "nginx-client-certs",
    "readOnly": true
  }
},
{
  "op": "add",
  "path": "/spec/template/spec/volumes/0",
  "value": {
  "name": "nginx-client-certs",
    "secret": {
      "secretName": "nginx-client-certs",
      "optional": true
    }
  }
},
{
  "op": "add",
  "path": "/spec/template/spec/containers/0/volumeMounts/1",
  "value": {
    "mountPath": "/etc/istio/nginx-ca-certs",
    "name": "nginx-ca-certs",
    "readOnly": true
  }
},
{
  "op": "add",
  "path": "/spec/template/spec/volumes/1",
  "value": {
  "name": "nginx-ca-certs",
    "secret": {
      "secretName": "nginx-ca-certs",
      "optional": true
    }
  }
}]
EOF

oc -n istio-system patch --type=json deploy istio-egressgateway -p "$(cat gateway-path.json)"
