# Creating the first content admin

The admin console needs one platform admin before anyone can sign in. The API image contains a CLI command for it
(`python -m app.cli create-admin`). Run it **inside the running API container** with `az containerapp exec`, so the
command connects to the database exactly like the API does (private network, the `homeschool_app` role) and the
password never touches a file, a pipeline, a state file or a stored command line.

Prerequisites: the API is deployed with a real image (the release job has run, so the tables exist), you are logged in
with `az login`, and you have Contributor on the environment resource group.

Replace `<env>` with `dev`, `nonprod` or `prod` (names follow `ca-hs-<env>-api` / `rg-hs-<env>`; the exact values are in
`terraform output`).

## Steps (Windows PowerShell or any terminal)

1. dev only (it scales to zero): wake the API so a replica exists.

   ```powershell
   Invoke-WebRequest https://<api-fqdn>/healthz -UseBasicParsing | Out-Null
   ```

2. Open a shell in the container.

   ```powershell
   az containerapp exec --name ca-hs-<env>-api --resource-group rg-hs-<env> --command /bin/sh
   ```

3. In that shell run the command **without** a password on the command line. The CLI asks for it with a hidden prompt
   (Python `getpass`) and requires at least 12 characters.

   ```sh
   python -m app.cli create-admin --email admin@example.com --name "First Admin" --role super_admin
   ```

   `--role` is `content_admin` (default) or `super_admin`. Running the command again for an existing email resets that
   person's password and role.

4. Leave the shell with `exit`.

### If the prompt echoes what you type

`az containerapp exec` normally allocates a terminal, so the prompt is hidden. If yours echoes, use this instead, which
switches echo off explicitly and keeps the password only in an environment variable of that one shell process:

```sh
stty -echo; printf 'Admin password: '; read ADMIN_PASSWORD; stty echo; echo
export ADMIN_PASSWORD
python -m app.cli create-admin --email admin@example.com --name "First Admin" --role super_admin
unset ADMIN_PASSWORD
exit
```

## What NOT to do

* Do not pass the password as part of `--command`, as an `--env-vars` value, in a Terraform variable, a GitHub
  variable/secret, a script or a `.env` file. All of those end up in shell history, logs, state or the repository.
* Do not reuse the password anywhere else, and store it in your password manager.
* In prod, use a named personal admin account and change the password at first sign-in; delete or demote accounts that
  are no longer needed.

## Why exec into the API and not the release job?

The release job runs with the database **administrator** credentials (it has to create the role and change the schema).
Creating an application user does not need that power, so it is done with the API's least-privilege connection.
`az containerapp exec` needs at least one running replica: in prod (2 replicas) and nonprod (1) that is always the case;
dev needs the wake-up request in step 1.
