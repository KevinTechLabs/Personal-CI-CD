# environments

Desired state for each environment, written only by the CI promotion jobs
and read by the GitOps agent on AI-LAB. Each directory holds the compose
file, settings and the signed image digest that should be running.

Roll back an environment with `git revert <promotion commit>` on this branch.
