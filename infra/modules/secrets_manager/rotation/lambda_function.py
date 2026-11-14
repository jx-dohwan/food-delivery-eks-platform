"""Single-user Aurora master rotation; only the password in the app secret changes.

Password updates retain the existing RDS control-plane API pattern. Validation
uses a fresh, TLS-verified connection to the Aurora writer, never RDS Proxy.
"""
import json
import logging
import os
from functools import lru_cache
from pathlib import Path
import secrets as pysecrets
import string

import boto3
from botocore.config import Config
import pymysql

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
STEPS = {"createSecret", "setSecret", "testSecret", "finishSecret"}


@lru_cache(maxsize=2)
def _client(service):
    return boto3.client(service, config=Config(
        connect_timeout=3, read_timeout=10,
        retries={"mode": "standard", "total_max_attempts": 2},
    ))


def _gen_password(length=20):
    alphabet = string.ascii_letters + string.digits + "!#$%&*()-_=+[]{}<>:?"
    characters = [pysecrets.choice(group) for group in (
        string.ascii_lowercase, string.ascii_uppercase,
        string.digits, "!#$%&*()-_=+[]{}<>:?",
    )]
    characters.extend(pysecrets.choice(alphabet) for _ in range(length - 4))
    pysecrets.SystemRandom().shuffle(characters)
    return "".join(characters)


def _get_secret_dict(arn, stage, token=None):
    kwargs = {"SecretId": arn, "VersionStage": stage}
    if token is not None:
        kwargs["VersionId"] = token
    value = json.loads(_client("secretsmanager").get_secret_value(**kwargs)["SecretString"])
    if not isinstance(value, dict):
        raise ValueError("Invalid credential document")
    for key in ("username", "password", "dbname"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise ValueError("Required credential field missing")
    if not isinstance(value.get("port"), int) or isinstance(value["port"], bool) or not 1 <= value["port"] <= 65535:
        raise ValueError("Invalid database port")
    return value


def _target_and_pending(arn, token):
    current = _get_secret_dict(arn, "AWSCURRENT")
    pending = _get_secret_dict(arn, "AWSPENDING", token)
    # A privileged rotation function must not act on a different user's secret.
    if any(pending[key] != current[key] for key in ("username", "dbname", "port")):
        raise ValueError("Pending credential identity does not match current")
    cluster = _client("rds").describe_db_clusters(
        DBClusterIdentifier=os.environ["DB_CLUSTER_IDENTIFIER"]
    )["DBClusters"][0]
    if (cluster.get("DBClusterIdentifier") != os.environ["DB_CLUSTER_IDENTIFIER"]
            or cluster.get("DBClusterArn") != os.environ["DB_CLUSTER_ARN"]
            or cluster.get("Engine") != "aurora-mysql"
            or cluster.get("MasterUsername") != pending["username"]
            or cluster.get("Port") != pending["port"]
            or not cluster.get("Endpoint")):
        raise ValueError("Credential does not match configured Aurora target")
    return cluster, pending, current


def _validate_connection(cluster, credential):
    connection = pymysql.connect(
        host=cluster["Endpoint"], port=credential["port"],
        user=credential["username"], password=credential["password"],
        database=credential["dbname"],
        connect_timeout=5, read_timeout=5, write_timeout=5,
        ssl_ca=str(Path(__file__).with_name("rds-ca-bundle.pem")),
        ssl_verify_cert=True, ssl_verify_identity=True,
    )
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            if cursor.fetchone() != (1,):
                raise RuntimeError("Database validation returned an unexpected result")
    finally:
        connection.close()


def create_secret(arn, token):
    sm = _client("secretsmanager")
    try:
        _get_secret_dict(arn, "AWSPENDING", token)
        logger.info("createSecret: pending version already exists")
        return
    except sm.exceptions.ResourceNotFoundException:
        pass
    current = _get_secret_dict(arn, "AWSCURRENT")
    pending = dict(current)
    pending["password"] = _gen_password()
    sm.put_secret_value(SecretId=arn, ClientRequestToken=token,
                        SecretString=json.dumps(pending), VersionStages=["AWSPENDING"])
    logger.info("createSecret: pending version created")


def set_secret(arn, token):
    cluster, pending, current = _target_and_pending(arn, token)
    try:
        _validate_connection(cluster, pending)
        logger.info("setSecret: pending credential is already active")
        return
    except pymysql.err.OperationalError as error:
        # Only an authentication rejection means the password still needs to be
        # set. Network/TLS/query errors must not trigger a password reset.
        if not error.args or error.args[0] != 1045:
            raise
    # Confirm the existing credential belongs to this live target before using
    # the privileged control-plane API to replace its password.
    _validate_connection(cluster, current)
    _client("rds").modify_db_cluster(
        DBClusterIdentifier=os.environ["DB_CLUSTER_IDENTIFIER"],
        MasterUserPassword=pending["password"], ApplyImmediately=True,
    )
    logger.info("setSecret: Aurora password update requested")


def test_secret(arn, token):
    cluster, pending, _ = _target_and_pending(arn, token)
    _validate_connection(cluster, pending)
    logger.info("testSecret: pending DB authentication and SELECT 1 succeeded")


def finish_secret(arn, token):
    sm = _client("secretsmanager")
    versions = sm.describe_secret(SecretId=arn)["VersionIdsToStages"]
    if "AWSCURRENT" in versions.get(token, []):
        return
    if "AWSPENDING" not in versions.get(token, []):
        raise ValueError("Version is not pending")
    # Even a separately invoked finish must not promote an unusable credential.
    test_secret(arn, token)
    current = [v for v, stages in versions.items() if "AWSCURRENT" in stages]
    if len(current) != 1:
        raise ValueError("Expected one current version")
    sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                                   MoveToVersionId=token, RemoveFromVersionId=current[0])
    logger.info("finishSecret: pending version promoted to current")


def handler(event, context):
    # Never propagate raw SDK/DB errors: Lambda records exception messages and
    # database/SDK exceptions can contain credentials or the complete request.
    step = event.get("Step") if isinstance(event, dict) else None
    safe_step = step if isinstance(step, str) and step in STEPS else "invalid"
    try:
        if safe_step == "invalid":
            raise ValueError("Invalid rotation step")
        arn = event["SecretId"]
        token = event["ClientRequestToken"]
        if arn != os.environ["SECRET_ARN"] or not isinstance(token, str) or not 32 <= len(token) <= 64:
            raise ValueError("Invalid rotation identity")
        metadata = _client("secretsmanager").describe_secret(SecretId=arn)
        if metadata.get("RotationEnabled") is not True:
            raise ValueError("Rotation is disabled")
        stages = metadata.get("VersionIdsToStages", {}).get(token, [])
        if "AWSCURRENT" in stages:
            logger.info("Rotation step=%s: version already current", safe_step)
            return {"status": "ok", "step": step}
        if "AWSPENDING" not in stages:
            raise ValueError("Token must identify an AWSPENDING version")
        logger.info("Rotation step=%s started", safe_step)
        {"createSecret": create_secret, "setSecret": set_secret,
         "testSecret": test_secret, "finishSecret": finish_secret}[step](arn, token)
        return {"status": "ok", "step": step}
    except Exception:
        logger.error("Rotation step=%s failed", safe_step)
        raise RuntimeError("Rotation step failed; inspect lifecycle and target readiness") from None
