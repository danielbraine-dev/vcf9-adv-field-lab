# Installing VKS packages
# First change to cluster context -- vcf context use (and then select the context from the menu)
# Install Cert Manager
k create ns vks-packages
vcf package repository add standard-package-repo --url projects.packages.broadcom.com/vsphere/supervisor/packages/2025.8.19/vks-standard-packages:v2025.8.19 -n tkg-system
vcf package available list -n tkg-system
vcf package available get cert-manager.kubernetes.vmware.com -n tkg-system
vcf package install cert-manager -p cert-manager.kubernetes.vmware.com --namespace vks-packages --version 1.18.2+vmware.1-vks.1
vcf package installed get cert-manager -n vks-packages
kubectl -n cert-manager get all
# Install Contour
vcf package available get contour.kubernetes.vmware.com -n tkg-system
vcf package available get contour.kubernetes.vmware.com/1.32.0+vmware.1-vks.1 --default-values-file-output contour-data-values.yaml
 # edit the data-valus yaml and set envoy.service.type=LoadBalancer
k create ns contour
vcf package install contour -p contour.kubernetes.vmware.com -v 1.32.0+vmware.1-vks.1 --values-file contour-data-values.yaml -n contour


# Install Prometheus (note: requires Cert Manager and Contour first)
vcf package available get prometheus.kubernetes.vmware.com -n tkg-system
k -n tkg-system get packages | grep prometheus
# Generate the prometheus-data-values.yaml file.
vcf package available get prometheus.kubernetes.vmware.com/2.53.4+vmware.1-tkg.1 --default-values-file-output prometheus-data-values.yaml
