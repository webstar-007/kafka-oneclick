// ONE CLICK: Build with Parameters -> ACTION = deploy
// At the end Kafka UI is open on your laptop at http://localhost:18080
//
// ACTION choices:
//   deploy         build everything (servers, Kafka, Kafka UI, demo app) and open Kafka UI
//   failover-demo  stop broker 3, show nothing breaks, start it again (run after deploy)
//   open-ui        re-open the Kafka UI tunnel (after a laptop restart or sleep)
//   destroy        delete everything on AWS and close the tunnel
//
// Jenkins needs: Terraform, Ansible, AWS CLI for the "jenkins" user, and a credential of
// kind "Username with password" with ID aws-creds (username = access key id, password = secret key).

pipeline {
  agent any

  parameters {
    choice(name: 'ACTION', choices: ['deploy', 'failover-demo', 'open-ui', 'destroy'], description: 'What to do')
    string(name: 'AWS_REGION', defaultValue: 'us-east-1', description: 'AWS region')
  }

  environment {
    AWS_DEFAULT_REGION  = "${params.AWS_REGION}"
    TF_IN_AUTOMATION    = 'true'
    ANSIBLE_FORCE_COLOR = 'true'
    UI_PORT             = '18080'     // Kafka UI on your laptop: http://localhost:18080
  }

  options {
    timestamps()
    disableConcurrentBuilds()          // two builds must never use the same Terraform state
    timeout(time: 60, unit: 'MINUTES')
  }

  stages {

    stage('1. Get the code') {
      steps { checkout scm }
    }

    stage('2. Check the tools') {
      when { expression { params.ACTION in ['deploy', 'destroy'] } }
      steps {
        sh 'terraform version | head -1 && ansible --version | head -1 && aws --version'
      }
    }

    stage('3. Terraform: build the servers on AWS') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'aws-creds', usernameVariable: 'AWS_ACCESS_KEY_ID', passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
          sh '''
            terraform -chdir=terraform init -input=false
            terraform -chdir=terraform validate
            terraform -chdir=terraform apply -auto-approve -input=false -var region=${AWS_REGION}
          '''
        }
      }
    }

    stage('4. Ansible: install the Kafka cluster') {
      when { expression { params.ACTION == 'deploy' } }
      steps { dir('ansible') { sh 'ansible-playbook site.yml --tags install' } }
    }

    stage('5. Smoke test') {
      when { expression { params.ACTION == 'deploy' } }
      steps { dir('ansible') { sh 'ansible-playbook site.yml --tags smoke' } }
    }

    stage('6. Install Kafka UI and the demo app') {
      when { expression { params.ACTION == 'deploy' } }
      steps { dir('ansible') { sh 'ansible-playbook site.yml --tags topic,apps' } }
    }

    stage('7. Verify events are flowing') {
      when { expression { params.ACTION == 'deploy' } }
      steps { dir('ansible') { sh 'ansible-playbook site.yml --tags verify' } }
    }

    stage('8. Open Kafka UI on localhost:18080') {
      when { expression { params.ACTION in ['deploy', 'open-ui'] } }
      steps {
        // JENKINS_NODE_COOKIE and BUILD_ID tell Jenkins NOT to kill this background tunnel when the build ends.
        sh '''
          IP=$(terraform -chdir=terraform output -raw bastion_public_ip)
          KEY="$PWD/keys/kafka-demo.pem"
          pkill -f "127.0.0.1:${UI_PORT}:localhost:8080" || true
          sleep 1
          JENKINS_NODE_COOKIE=dontKillMe BUILD_ID=dontKillMe setsid ssh -f -N \
            -L 127.0.0.1:${UI_PORT}:localhost:8080 -i "$KEY" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
            ubuntu@"$IP" > /dev/null 2>&1
          for i in $(seq 1 15); do
            if curl -fsS http://127.0.0.1:${UI_PORT}/actuator/health > /dev/null; then
              echo "KAFKA UI IS READY: open http://localhost:${UI_PORT} in your browser"
              exit 0
            fi
            sleep 4
          done
          echo "Kafka UI did not answer through the tunnel. Is port ${UI_PORT} used by another program?"
          exit 1
        '''
      }
    }

    stage('Failover demo') {
      when { expression { params.ACTION == 'failover-demo' } }
      steps { dir('ansible') { sh 'ansible-playbook failover.yml' } }
    }

    stage('Destroy: close the tunnel and delete everything') {
      when { expression { params.ACTION == 'destroy' } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'aws-creds', usernameVariable: 'AWS_ACCESS_KEY_ID', passwordVariable: 'AWS_SECRET_ACCESS_KEY')]) {
          sh '''
            pkill -f "127.0.0.1:${UI_PORT}:localhost:8080" || true
            terraform -chdir=terraform init -input=false
            terraform -chdir=terraform destroy -auto-approve -input=false -var region=${AWS_REGION}
          '''
        }
      }
    }
  }

  post {
    success { echo "Finished: ${params.ACTION}" }
    failure { echo 'FAILED. If servers were created, run again with ACTION=destroy to stop AWS charges.' }
    // No cleanWs() on purpose: the workspace holds the Terraform state and the SSH key.
  }
}
