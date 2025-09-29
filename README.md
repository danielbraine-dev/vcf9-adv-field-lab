# vcf9-adv-deploy-lab-setup

Open a Terminal on the Linux console and copy/paste the following commands. Enter the lab password when prompted.

sudo sed -i '0,/multiverse/s/multiverse/multiverse\ main\ restricted\ universe/' /etc/apt/sources.list.d/ubuntu.sources && \
sudo apt update -y && \
sudo apt install git -y && \
cd ~/Downloads && \
git clone https://github.com/danielbraine-dev/vcf9-adv-deploy-lab-setup.git && \
cd vcf9-adv-deploy-lab-setup/terraform/clean_and_stage && \
chmod +x setup.sh && \
./setup.sh


Relax the Pod Security on the default namespace:
vcf context use vks-cluster-qxml:kubernetes-cluster-qxml
kubectl label --overwrite namespace default pod-security.kubernetes.io/enforce=privileged
