echo "Creating Supervisor context..."
vcf context create sup-wld --endpoint 10.1.0.2 -u administrator@wld.sso --insecure-skip-tls-verify --type k8s --auth-type basic

echo "Creating VKS workload cluster context..."
vcf context create vks-cluster-qxml --endpoint 10.1.0.2 -u administrator@wld.sso --insecure-skip-tls-verify --workload-cluster-name kubernetes-cluster-qxml --workload-cluster-namespace demo-namespace-vkrcg --type k8s --auth-type basic

echo "Setting sup-wld context as current..."
vcf context use sup-wld

source ~/.bashrc

echo "All commands processed. Restart the Terminal now!!!"
