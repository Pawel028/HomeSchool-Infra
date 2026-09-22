#!/usr/bin/env python3
"""Repository consistency checks for the infra repo.

This is a small, repo-specific static checker (not a generic HCL linter). It knows the exact shape of the files
in this repository and cross-checks things that `terraform validate` cannot see: parity between the three
environments, the "protected/unprotected" resource twins, the wiring between Terraform outputs and the values
operators feed into GitHub, and (most importantly) that the Container Apps environment variables this repo
defines actually line up with backend-api's `app/config.py`.

Checks:
  1. env parity      - envs/dev, envs/nonprod, envs/prod share byte-identical main.tf, variables.tf, outputs.tf,
                        providers.tf, versions.tf, backend.tf. Only <env>.tfvars and backend.hcl.example may differ.
  2. protected twins  - modules/keyvault/main.tf's azurerm_key_vault.protected/.unprotected, and
                        modules/postgres/main.tf's azurerm_postgresql_flexible_server.protected/.unprotected, are
                        identical except for `count` and the `lifecycle` block.
  3. secret wiring    - the Key Vault secret names modules/keyvault/main.tf creates match exactly the set
                        modules/container_apps/variables.tf requires in key_vault_secret_ids.
  4. output wiring    - envs/*/outputs.tf's github_environment_variables output has exactly the four keys the
                        deploy pipelines (scripts/setup-github-oidc.ps1, backend-api's deploy.yml) expect:
                        ACR_NAME, CONTAINER_APP_NAME, RELEASE_JOB_NAME, AZURE_RESOURCE_GROUP.
  5. env vars <-> Settings (skippable with --no-backend, or automatically if backend-api is not found)
                        every NON-secret env var name modules/container_apps/main.tf sets on the API container or
                        the release job exists, case-insensitively (UPPER_SNAKE -> snake_case), as a field of
                        backend-api's app.config.Settings - EXCEPT a short, documented allow-list of release-job-only
                        variables that app/cli.py reads directly with os.environ and that are deliberately not part
                        of the pydantic-settings model.
  6. secrets via KV   - DB_PASSWORD, JWT_SECRET, OTP_WEBHOOK_TOKEN and APP_DB_PASSWORD are never set as a plain
                        `value` on the API container or the release job; they only ever appear as Container Apps
                        `secret` references (key_vault_secret_id), matching the module's own "SECRETS" contract
                        documented at the top of modules/container_apps/main.tf.
  7. prod validator   - envs/prod/prod.tfvars (plus the values modules/container_apps/main.tf hardcodes) satisfy
                        backend-api's production guard (app.config.Settings._guard_deployed_environments):
                        cors_origins never "*", db_sslmode >= require, expose_dev_otp = false, and when
                        otp_provider = webhook, otp_webhook_url is an https:// URL. Known, intentionally-committed
                        placeholders (otp_webhook_url, alert_email) are reported as NOTES, not errors: they are
                        meant to make `terraform plan` fail for prod until a human replaces them (see prod.tfvars),
                        not a bug in this repository.

Usage:
    python tools/check-consistency.py                       # looks for ../backend-api next to this checkout
    python tools/check-consistency.py --backend ../backend-api
    python tools/check-consistency.py --no-backend           # skip check 5 outright (used by terraform-plan.yml,
                                                               # which does not check out backend-api)

Exit code: 0 if no ERROR-level problem was found (NOTEs and the "backend-api not found" skip do not fail the
build), 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ENVS = ["dev", "nonprod", "prod"]
SHARED_ENV_FILES = ["main.tf", "variables.tf", "outputs.tf", "providers.tf", "versions.tf", "backend.tf"]

# Release-job-only variables that app/cli.py reads straight from os.environ (not through app.config.Settings),
# so they are correctly absent from the Settings model. See app/cli.py: ensure_app_role() reads APP_DB_USER via
# `--user`/argparse default os.getenv("APP_DB_USER", ...); main()'s "release" branch reads SEED_PUBLISH via
# os.getenv("SEED_PUBLISH", "false"). Keep this list short and documented; anything else missing from Settings
# is a real problem.
ENV_VAR_SETTINGS_EXEMPTIONS = {
    "APP_DB_USER": "release job only; app/cli.py ensure_app_role() reads it via argparse/os.getenv, not Settings",
    "SEED_PUBLISH": "release job only; app/cli.py release branch reads it via os.getenv, not Settings",
}

SECRET_ENV_VARS = {"DB_PASSWORD", "JWT_SECRET", "OTP_WEBHOOK_TOKEN", "APP_DB_PASSWORD"}

EXPECTED_GITHUB_ENV_VARS = {"ACR_NAME", "CONTAINER_APP_NAME", "RELEASE_JOB_NAME", "AZURE_RESOURCE_GROUP"}


class Problem:
    def __init__(self, level: str, check: str, message: str):
        self.level = level  # "ERROR" or "NOTE"
        self.check = check
        self.message = message

    def __str__(self) -> str:
        return f"[{self.level:5}] {self.check}: {self.message}"


PROBLEMS: list[Problem] = []


def error(check: str, message: str) -> None:
    PROBLEMS.append(Problem("ERROR", check, message))


def note(check: str, message: str) -> None:
    PROBLEMS.append(Problem("NOTE", check, message))


def ok(check: str, message: str) -> None:
    print(f"  ok   {check}: {message}")


# ---- small HCL helpers (brace-matching, not a full parser - this repo's files are all this simple) --------------


def find_matching_brace(text: str, open_idx: int) -> int:
    """open_idx must point at a '{'. Returns the index just after the matching '}'."""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("unbalanced braces starting at index %d" % open_idx)


def extract_block(text: str, header_pattern: str) -> str | None:
    """Returns the full 'header { ... }' text for the first match of header_pattern, or None."""
    m = re.search(header_pattern, text)
    if not m:
        return None
    open_idx = text.index("{", m.end() - 1)
    end = find_matching_brace(text, open_idx)
    return text[m.start() : end]


def remove_named_block(text: str, name: str) -> str:
    m = re.search(r"\b%s\s*\{" % re.escape(name), text)
    if not m:
        return text
    open_idx = text.index("{", m.end() - 1)
    end = find_matching_brace(text, open_idx)
    return text[: m.start()] + text[end:]


def normalize_resource_body(block: str) -> str:
    """Strips the header, the `count = ...` line and any `lifecycle { ... }` block, for a same-except-those diff."""
    body = block[block.index("{") + 1 : block.rindex("}")]
    body = remove_named_block(body, "lifecycle")
    lines = []
    for line in body.splitlines():
        s = line.strip()
        if not s or re.match(r"^count\s*=", s):
            continue
        lines.append(s)
    return "\n".join(lines)


def extract_map_keys(text: str, map_header_pattern: str) -> list[str] | None:
    """For `name = { KEY = value, ... }` or `name = merge(other, { KEY = value, ... })`, returns the KEY names
    declared directly in that map (top-level lines of the shape `IDENT = ...`)."""
    block = extract_block(text, map_header_pattern)
    if block is None:
        return None
    inner = block[block.index("{") + 1 : block.rindex("}")]
    keys = []
    for line in inner.splitlines():
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m:
            keys.append(m.group(1))
    return keys


# ---- checks --------------------------------------------------------------------------------------------------


def check_env_parity() -> None:
    print("\n[1/7] Environment parity (dev / nonprod / prod share the same wiring)")
    base_env = ENVS[0]
    any_diff = False
    for fname in SHARED_ENV_FILES:
        base_path = REPO_ROOT / "envs" / base_env / fname
        if not base_path.exists():
            error("env-parity", f"envs/{base_env}/{fname} is missing")
            any_diff = True
            continue
        base_text = base_path.read_text()
        for env in ENVS[1:]:
            other_path = REPO_ROOT / "envs" / env / fname
            if not other_path.exists():
                error("env-parity", f"envs/{env}/{fname} is missing")
                any_diff = True
                continue
            other_text = other_path.read_text()
            if other_text != base_text:
                error("env-parity", f"envs/{env}/{fname} differs from envs/{base_env}/{fname}")
                any_diff = True
    if not any_diff:
        ok("env-parity", f"{', '.join(SHARED_ENV_FILES)} are identical across {', '.join(ENVS)}")


def check_protected_twins() -> None:
    print("\n[2/7] protected/unprotected resource twins")
    targets = [
        ("modules/keyvault/main.tf", "azurerm_key_vault", "protected", "unprotected"),
        ("modules/postgres/main.tf", "azurerm_postgresql_flexible_server", "protected", "unprotected"),
    ]
    for rel_path, rtype, name_a, name_b in targets:
        path = REPO_ROOT / rel_path
        if not path.exists():
            error("protected-twins", f"{rel_path} is missing")
            continue
        text = path.read_text()
        block_a = extract_block(text, r'resource\s+"%s"\s+"%s"\s*\{' % (re.escape(rtype), name_a))
        block_b = extract_block(text, r'resource\s+"%s"\s+"%s"\s*\{' % (re.escape(rtype), name_b))
        if block_a is None or block_b is None:
            error("protected-twins", f"{rel_path}: could not find both resource \"{rtype}\" \"{name_a}\"/\"{name_b}\"")
            continue
        norm_a, norm_b = normalize_resource_body(block_a), normalize_resource_body(block_b)
        if norm_a != norm_b:
            error(
                "protected-twins",
                f"{rel_path}: {rtype}.{name_a} and .{name_b} differ beyond `count` and `lifecycle` "
                f"(prevent_destroy would not be the only difference)",
            )
        else:
            ok("protected-twins", f"{rel_path}: {rtype}.{name_a}/.{name_b} identical except count/lifecycle")


def check_secret_wiring() -> None:
    print("\n[3/7] Key Vault secret names <-> container_apps key_vault_secret_ids")
    kv_path = REPO_ROOT / "modules" / "keyvault" / "main.tf"
    ca_vars_path = REPO_ROOT / "modules" / "container_apps" / "variables.tf"
    if not kv_path.exists() or not ca_vars_path.exists():
        error("secret-wiring", "modules/keyvault/main.tf or modules/container_apps/variables.tf is missing")
        return
    kv_text = kv_path.read_text()
    created = set(re.findall(r'resource\s+"azurerm_key_vault_secret"\s+"\w+"\s*\{\s*\n\s*name\s*=\s*"([\w-]+)"', kv_text))
    ca_text = ca_vars_path.read_text()
    required_block = extract_block(ca_text, r'variable\s+"key_vault_secret_ids"\s*\{')
    required = set(re.findall(r'"([\w-]+)"', required_block)) if required_block else set()
    # the regex above also matches the description string's words in quotes only if quoted; keep just the ones that
    # look like our kebab-case secret names and are inside the validation's contains([...]) list.
    validation_list = extract_block(required_block or "", r"validation\s*\{") if required_block else None
    if validation_list:
        required = set(re.findall(r'"([a-z][a-z-]*)"', validation_list))
    if not created:
        error("secret-wiring", "modules/keyvault/main.tf creates no azurerm_key_vault_secret resources")
    elif not required:
        error("secret-wiring", "modules/container_apps/variables.tf key_vault_secret_ids validation list not found")
    elif created != required:
        error(
            "secret-wiring",
            f"Key Vault creates {sorted(created)} but container_apps requires {sorted(required)} "
            f"(missing: {sorted(required - created)}, extra: {sorted(created - required)})",
        )
    else:
        ok("secret-wiring", f"both sides agree on {sorted(created)}")


def check_output_wiring() -> None:
    print("\n[4/7] github_environment_variables output wiring")
    for env in ENVS:
        path = REPO_ROOT / "envs" / env / "outputs.tf"
        if not path.exists():
            error("output-wiring", f"envs/{env}/outputs.tf is missing")
            continue
        text = path.read_text()
        block = extract_block(text, r'output\s+"github_environment_variables"\s*\{')
        if block is None:
            error("output-wiring", f"envs/{env}/outputs.tf has no github_environment_variables output")
            continue
        keys = set(re.findall(r"^\s*([A-Z_]+)\s*=", block, flags=re.MULTILINE))
        if keys != EXPECTED_GITHUB_ENV_VARS:
            error(
                "output-wiring",
                f"envs/{env}/outputs.tf github_environment_variables has {sorted(keys)}, "
                f"expected {sorted(EXPECTED_GITHUB_ENV_VARS)}",
            )
    if not any(p.check == "output-wiring" for p in PROBLEMS):
        ok("output-wiring", f"all environments expose exactly {sorted(EXPECTED_GITHUB_ENV_VARS)}")


def load_container_apps_env_names() -> tuple[set[str], set[str]] | None:
    """Returns (non_secret_names, secret_names) declared in modules/container_apps/main.tf, or None if unreadable."""
    path = REPO_ROOT / "modules" / "container_apps" / "main.tf"
    if not path.exists():
        error("env-vars", "modules/container_apps/main.tf is missing")
        return None
    text = path.read_text()

    common = extract_map_keys(text, r"common_env\s*=\s*\{") or []
    api_extra = extract_map_keys(text, r"api_env\s*=\s*merge\(local\.common_env,\s*\{") or []
    job_extra = extract_map_keys(text, r"job_env\s*=\s*merge\(local\.common_env,\s*\{") or []
    non_secret = set(common) | set(api_extra) | set(job_extra)

    api_secret = extract_map_keys(text, r"api_secret_env\s*=\s*\{") or []
    job_secret = extract_map_keys(text, r"job_secret_env\s*=\s*\{") or []
    secret = set(api_secret) | set(job_secret)

    return non_secret, secret


def load_settings_fields(backend_dir: Path) -> set[str] | None:
    config_path = backend_dir / "app" / "config.py"
    if not config_path.exists():
        return None
    text = config_path.read_text()
    m = re.search(r"class Settings\(BaseSettings\):\n", text)
    if not m:
        return None
    # class body = every subsequent line indented (until a line that starts at column 0, i.e. dedents back to
    # module level - the next top-level `class`/`def`/`@lru_cache` etc.)
    body_lines = []
    for line in text[m.end() :].splitlines():
        if line and not line[0].isspace():
            break
        body_lines.append(line)
    body = "\n".join(body_lines)
    fields = set(re.findall(r"^    ([a-z][a-z0-9_]*)\s*:\s", body, flags=re.MULTILINE))
    return fields


def check_env_vars_vs_settings(backend_dir: Path | None) -> None:
    print("\n[5/7] Container Apps env vars <-> backend-api Settings fields")
    if backend_dir is None:
        note("env-vars", "skipped (--no-backend, or backend-api was not found next to this checkout)")
        return
    non_secret_secret = load_container_apps_env_names()
    if non_secret_secret is None:
        return
    non_secret, _secret = non_secret_secret
    fields = load_settings_fields(backend_dir)
    if fields is None:
        note("env-vars", f"skipped: could not read Settings fields from {backend_dir}/app/config.py")
        return

    missing = []
    for name in sorted(non_secret):
        if name in ENV_VAR_SETTINGS_EXEMPTIONS:
            continue
        if name.lower() not in fields:
            missing.append(name)
    if missing:
        for name in missing:
            error("env-vars", f"{name} is set on the Container App/Job but app.config.Settings has no `{name.lower()}` field")
    else:
        exempt = sorted(n for n in non_secret if n in ENV_VAR_SETTINGS_EXEMPTIONS)
        ok(
            "env-vars",
            f"every non-secret env var maps to a Settings field "
            f"({len(non_secret) - len(exempt)} checked, exempt: {exempt})",
        )


def check_secrets_via_key_vault() -> None:
    print("\n[6/7] Secrets are sourced from Key Vault, never a plain value")
    path = REPO_ROOT / "modules" / "container_apps" / "main.tf"
    if not path.exists():
        error("secrets-kv", "modules/container_apps/main.tf is missing")
        return
    text = path.read_text()

    non_secret_secret = load_container_apps_env_names()
    if non_secret_secret is None:
        return
    non_secret, secret = non_secret_secret

    problems_found = False
    for name in sorted(SECRET_ENV_VARS):
        if name not in secret:
            error("secrets-kv", f"{name} is not declared in api_secret_env or job_secret_env")
            problems_found = True
        if name in non_secret:
            error("secrets-kv", f"{name} is ALSO set as a plain (non-secret) env var - it would leak a value outside Key Vault")
            problems_found = True

    # Every `secret { ... }` (or its `dynamic "secret"` content block) must resolve its value from Key Vault, never
    # a literal string.
    secret_value_blocks = re.findall(r"content\s*\{\s*name\s*=\s*secret\.key.*?\}", text, flags=re.DOTALL)
    if not secret_value_blocks:
        error("secrets-kv", "no `secret` block content found on the Container App / Job")
        problems_found = True
    for block in secret_value_blocks:
        if "key_vault_secret_id" not in block:
            error("secrets-kv", f"a `secret` block does not use key_vault_secret_id: {block.strip()[:120]}...")
            problems_found = True
        if re.search(r'value\s*=\s*"', block):
            error("secrets-kv", f"a `secret` block sets a literal string value: {block.strip()[:120]}...")
            problems_found = True

    # And the env vars that carry those secrets into the container must use secret_name, never value.
    for local_name in ["api_secret_env", "job_secret_env"]:
        env_block = extract_block(text, r'dynamic\s+"env"\s*\{\s*\n\s*for_each\s*=\s*local\.%s' % local_name)
        if env_block is None:
            error("secrets-kv", f"could not find the `dynamic \"env\"` block driven by local.{local_name}")
            problems_found = True
            continue
        if "secret_name = env.value" not in env_block:
            error("secrets-kv", f"the `dynamic \"env\"` block for local.{local_name} does not set secret_name = env.value")
            problems_found = True
        if re.search(r"\bvalue\s*=\s*env\.value\b", env_block):
            error("secrets-kv", f"the `dynamic \"env\"` block for local.{local_name} sets a plain value from a secret map")
            problems_found = True

    if not problems_found:
        ok("secrets-kv", f"{sorted(SECRET_ENV_VARS)} are only ever wired through Key Vault secret references")


def parse_tfvars(path: Path) -> dict[str, str]:
    """Minimal top-level tfvars parser: KEY = <rest of line, possibly a list literal>. Good enough for this repo's
    flat tfvars files (no nested maps)."""
    values: dict[str, str] = {}
    text = path.read_text()
    # Strip full-line and trailing comments (simple: no '#' occurs inside a value in these files).
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, _, rest = line.partition("=")
        values[key.strip()] = rest.strip()
    return values


def check_prod_validator(backend_dir: Path | None) -> None:
    print("\n[7/7] envs/prod/prod.tfvars against backend-api's production guard")
    prod_tfvars = REPO_ROOT / "envs" / "prod" / "prod.tfvars"
    ca_main = REPO_ROOT / "modules" / "container_apps" / "main.tf"
    ca_vars = REPO_ROOT / "envs" / "prod" / "variables.tf"
    if not prod_tfvars.exists() or not ca_main.exists():
        error("prod-guard", "envs/prod/prod.tfvars or modules/container_apps/main.tf is missing")
        return

    tfvars = parse_tfvars(prod_tfvars)
    ca_text = ca_main.read_text()
    env_vars_text = ca_vars.read_text() if ca_vars.exists() else ""
    ca_vars_path = REPO_ROOT / "modules" / "container_apps" / "variables.tf"
    ca_vars_text = ca_vars_path.read_text() if ca_vars_path.exists() else ""

    # expose_dev_otp: hardcoded in the module, never a tfvars knob - verify it is literally "false".
    m = re.search(r'EXPOSE_DEV_OTP\s*=\s*"([^"]*)"', ca_text)
    if not m or m.group(1) != "false":
        error("prod-guard", "modules/container_apps/main.tf does not hardcode EXPOSE_DEV_OTP = \"false\"")
    else:
        ok("prod-guard", "EXPOSE_DEV_OTP is hardcoded false for every environment (never a tfvars knob)")

    # db_sslmode: hardcoded in the module - must be require or stronger (never disable/allow/prefer).
    m = re.search(r'DB_SSLMODE\s*=\s*"([^"]*)"', ca_text)
    if not m or m.group(1) not in ("require", "verify-ca", "verify-full"):
        error("prod-guard", f"modules/container_apps/main.tf DB_SSLMODE is {m.group(1) if m else 'MISSING'}, expected require/verify-ca/verify-full")
    else:
        ok("prod-guard", f"DB_SSLMODE is hardcoded \"{m.group(1)}\" (satisfies db_sslmode >= require)")

    # cors: prod builds CORS_ORIGINS from the two Static Web App hostnames plus extra_cors_origins; the wildcard
    # is blocked structurally by two validations - modules/container_apps/variables.tf's cors_origins itself, and
    # envs/*/variables.tf's extra_cors_origins (which feeds it) - never by a literal "*" anywhere.
    module_guard = "cors_origins must list explicit origins" in ca_vars_text
    extra_origins_guard = "extra_cors_origins entries must be explicit" in env_vars_text
    if module_guard and extra_origins_guard:
        ok("prod-guard", "cors_origins can never be \"*\" (module-level regex validation + extra_cors_origins validation)")
    else:
        missing = []
        if not module_guard:
            missing.append("modules/container_apps/variables.tf cors_origins wildcard validation")
        if not extra_origins_guard:
            missing.append("envs/prod/variables.tf extra_cors_origins validation")
        error("prod-guard", f"could not find: {', '.join(missing)}")

    # jwt secret: generated by random_password (64 chars, no PLACEHOLDER_SECRETS collision possible), never a
    # tfvars value - check the length is still >= 32 at the source.
    kv_main = (REPO_ROOT / "modules" / "keyvault" / "main.tf").read_text()
    m = re.search(r'resource\s+"random_password"\s+"jwt_secret"\s*\{\s*\n\s*length\s*=\s*(\d+)', kv_main)
    if not m or int(m.group(1)) < 32:
        error("prod-guard", "modules/keyvault/main.tf random_password.jwt_secret length is missing or below 32")
    else:
        ok("prod-guard", f"jwt-secret is a random {m.group(1)}-character value from Key Vault (>= 32, never a placeholder)")

    # otp_provider / otp_webhook_url: real production values, but the repository deliberately ships a placeholder
    # URL so `terraform plan` fails until a human sets the real one - report that as a NOTE, not an error.
    otp_provider = tfvars.get("otp_provider", "").strip('"')
    otp_webhook_url = tfvars.get("otp_webhook_url", "").strip('"')
    if otp_provider != "webhook":
        error("prod-guard", f'envs/prod/prod.tfvars otp_provider = "{otp_provider}", must be "webhook" in prod')
    elif not otp_webhook_url.startswith("https://"):
        error("prod-guard", "envs/prod/prod.tfvars otp_webhook_url is not an https:// URL")
    elif re.search(r"(?i)replace-me|\.invalid(/|$)", otp_webhook_url):
        note(
            "prod-guard",
            f'otp_webhook_url is still the shipped placeholder ("{otp_webhook_url}"); '
            f"envs/prod/variables.tf's validation will fail `terraform plan` until an operator replaces it "
            f"(by design - see prod.tfvars).",
        )
    else:
        ok("prod-guard", "otp_provider = webhook with a real https otp_webhook_url")

    alert_email = tfvars.get("alert_email", "").strip('"')
    if tfvars.get("enable_alerts", "").strip() == "true":
        if re.search(r"(?i)replace-me|\.invalid$", alert_email):
            note(
                "prod-guard",
                f'alert_email is still the shipped placeholder ("{alert_email}"); '
                f"envs/prod/variables.tf's validation will fail `terraform plan` until an operator replaces it "
                f"(by design - see prod.tfvars).",
            )

    # sanity: if backend-api is available, make sure the guard we are mirroring still says what we think it says.
    if backend_dir is not None:
        config_path = backend_dir / "app" / "config.py"
        if config_path.exists():
            guard_text = config_path.read_text()
            expected_snippets = [
                "CORS_ORIGINS must list explicit origins",
                "DB_SSLMODE must be require or stronger",
                "EXPOSE_DEV_OTP must be false",
                "OTP_PROVIDER must be webhook in prod",
                "OTP_WEBHOOK_URL must be an https URL",
            ]
            missing_snippets = [s for s in expected_snippets if s not in guard_text]
            if missing_snippets:
                error(
                    "prod-guard",
                    f"app/config.py's _guard_deployed_environments no longer contains: {missing_snippets} "
                    f"- this script's mirrored checks may be stale, update both together",
                )
            else:
                ok("prod-guard", "backend-api's _guard_deployed_environments still matches the rules mirrored here")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", type=Path, default=None, help="path to a backend-api checkout (default: ../backend-api next to this repo)")
    ap.add_argument("--no-backend", action="store_true", help="skip checks that need backend-api's app/config.py")
    args = ap.parse_args()

    backend_dir: Path | None = None
    if not args.no_backend:
        candidate = args.backend if args.backend is not None else (REPO_ROOT.parent / "backend-api")
        if (candidate / "app" / "config.py").exists():
            backend_dir = candidate
        elif args.backend is not None:
            error("setup", f"--backend {candidate} does not contain app/config.py")
        # else: silently fall back to the "not found, skip" NOTE emitted by the individual checks - this is the
        # expected case for terraform-plan.yml, which does not check out backend-api.

    print(f"infra repository consistency checks (repo root: {REPO_ROOT})")
    if backend_dir:
        print(f"backend-api found at: {backend_dir}")
    else:
        print("backend-api not found - checks 5 and part of 7 will be skipped/limited (pass --backend to run them)")

    check_env_parity()
    check_protected_twins()
    check_secret_wiring()
    check_output_wiring()
    check_env_vars_vs_settings(backend_dir)
    check_secrets_via_key_vault()
    check_prod_validator(backend_dir)

    errors = [p for p in PROBLEMS if p.level == "ERROR"]
    notes = [p for p in PROBLEMS if p.level == "NOTE"]

    print("\n" + "=" * 100)
    if PROBLEMS:
        for p in PROBLEMS:
            print(str(p))
    print(f"\n{len(errors)} error(s), {len(notes)} note(s).")
    if errors:
        print("FAILED")
        return 1
    print("PASSED" + (" (with notes above - expected placeholders, no action needed in CI)" if notes else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
