# vcf9-adv-deploy-lab-setup

Open a Terminal on the Linux console and copy/paste the following commands. Enter the lab password when prompted.
Make sure to download the AVI controller OVA and place it in the ~/Downloads/vcf9-adv-field-lab/terraform/clean_and_stage folder
prior to step 5.

Commands:

   sudo sed -i '0,/multiverse/s/multiverse/multiverse\ main\ restricted\ universe/' /etc/apt/sources.list.d/ubuntu.sources && \
   sudo apt update -y && \
   sudo apt install git -y && \
   cd ~/Downloads && \
   git clone https://github.com/danielbraine-dev/vcf9-adv-field-lab.git && \
   cd vcf9-adv-field-lab/terraform/clean_and_stage && \
   chmod +x setup.sh && \
   ./setup.sh


**Use these options via direct calling, or via sequential steps i.e.: setup.sh 1:9 to perform steps 1 through 9
**
   - 1) step1_install_tools;;
   - 2) step2_teardown_environment;;
   - 3) step3_tf_init;;
   - 4) step4_create_nsx_objects;;
   - 5) step5_deploy_avi;;
   - 6) step6_init_avi;;
   - 7) step7_avi_base_config;;
   - 8) step8_nsx_cloud;;
   - 9) step9_install_sup;;
   - 10) step10_prime_vcfa_objects;;
   - 11) step11_deploy_openldap;;

Additional Help:
Do you need to Relax the Pod Security on the a namespace:
i.e.: 
Switch to the appropriate context: vcf context use vks-cluster-qxml:kubernetes-cluster-qxml
Change the label: kubectl label --overwrite namespace default pod-security.kubernetes.io/enforce=privileged
