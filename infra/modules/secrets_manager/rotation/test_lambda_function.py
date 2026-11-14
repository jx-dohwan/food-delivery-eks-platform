"""Offline lifecycle/security regression tests: no AWS API or database calls."""
import copy
import importlib
import io
import json
import logging
import os
from pathlib import Path
import ssl
import sys
import traceback
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "build"))
rotation = importlib.import_module("lambda_function")

ARN = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds-aurora-credentials-example"
CLUSTER_ARN = "arn:aws:rds:ap-northeast-2:123456789012:cluster:aurora-mysql-cluster"
CURRENT = "11111111-1111-1111-1111-111111111111"
TOKEN = "22222222-2222-2222-2222-222222222222"


class MissingSecret(Exception):
    pass


class RotationTest(unittest.TestCase):
    def setUp(self):
        self.current = {"username": "appadmin", "password": "CURRENT_SECRET",
                        "port": 3306, "dbname": "fooddelivery",
                        "redis_host": "redis.internal", "redis_port": 6379,
                        "jwt_access_secret": "PRIVATE_JWT", "jwt_refresh_secret": "PRIVATE_REFRESH"}
        self.pending = {**self.current, "password": "PENDING_SECRET"}
        self.versions = {CURRENT: ["AWSCURRENT"], TOKEN: ["AWSPENDING"]}
        self.values = {CURRENT: self.current, TOKEN: self.pending}
        self.sm = MagicMock()
        self.sm.exceptions.ResourceNotFoundException = MissingSecret
        self.sm.describe_secret.side_effect = lambda **kw: {
            "RotationEnabled": True, "VersionIdsToStages": copy.deepcopy(self.versions)}
        self.sm.get_secret_value.side_effect = self.get_value
        self.sm.put_secret_value.side_effect = self.put_value
        self.sm.update_secret_version_stage.side_effect = self.promote
        self.rds = MagicMock()
        self.cluster = {"DBClusterIdentifier": "aurora-mysql-cluster", "DBClusterArn": CLUSTER_ARN,
                        "Engine": "aurora-mysql", "MasterUsername": "appadmin", "Port": 3306,
                        "Endpoint": "aurora-mysql-cluster.cluster-example.ap-northeast-2.rds.amazonaws.com"}
        self.rds.describe_db_clusters.return_value = {"DBClusters": [self.cluster]}
        self.connection = MagicMock()
        self.cursor = self.connection.cursor.return_value.__enter__.return_value
        self.cursor.fetchone.return_value = (1,)
        self.clients = patch.object(rotation, "_client", side_effect=lambda name: {
            "secretsmanager": self.sm, "rds": self.rds}[name])
        self.client_mock = self.clients.start()
        self.db = patch.object(rotation.pymysql, "connect", return_value=self.connection)
        self.connect = self.db.start()
        self.environment = patch.dict(os.environ, {"SECRET_ARN": ARN,
            "DB_CLUSTER_IDENTIFIER": "aurora-mysql-cluster", "DB_CLUSTER_ARN": CLUSTER_ARN})
        self.environment.start()
        self.addCleanup(self.clients.stop)
        self.addCleanup(self.db.stop)
        self.addCleanup(self.environment.stop)

    def get_value(self, **kwargs):
        version = kwargs.get("VersionId")
        if version is None:
            version = next((v for v, stages in self.versions.items()
                            if kwargs["VersionStage"] in stages), None)
        if version not in self.values or kwargs["VersionStage"] not in self.versions.get(version, []):
            raise MissingSecret("Secret value not available")
        return {"SecretString": json.dumps(self.values[version])}

    def put_value(self, **kwargs):
        self.values[kwargs["ClientRequestToken"]] = json.loads(kwargs["SecretString"])

    def promote(self, **kwargs):
        self.versions[kwargs["RemoveFromVersionId"]] = ["AWSPREVIOUS"]
        self.versions[kwargs["MoveToVersionId"]] = ["AWSCURRENT"]

    def invoke(self, step, **kwargs):
        event = {"SecretId": ARN, "ClientRequestToken": TOKEN, "Step": step, **kwargs}
        return rotation.handler(event, None)

    def test_invalid_step_rejected_before_access(self):
        for step in ["unsupported", "PENDING_SECRET", None, []]:
            with self.subTest(step=step), self.assertRaises(RuntimeError):
                self.invoke(step)
        self.client_mock.assert_not_called()

    def test_wrong_secret_and_token_rejected(self):
        for changes in [{"SecretId": "other-secret"}, {"ClientRequestToken": "short"},
                        {"ClientRequestToken": "33333333-3333-3333-3333-333333333333"}]:
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                self.invoke("createSecret", **changes)
        self.sm.put_secret_value.assert_not_called()
        self.rds.modify_db_cluster.assert_not_called()

    def test_all_steps_require_pending_stage(self):
        self.versions[TOKEN] = ["AWSPREVIOUS"]
        for step in rotation.STEPS:
            with self.subTest(step=step), self.assertRaises(RuntimeError):
                self.invoke(step)
        self.sm.put_secret_value.assert_not_called()
        self.sm.update_secret_version_stage.assert_not_called()

    def test_rotation_disabled_rejected(self):
        self.sm.describe_secret.side_effect = None
        self.sm.describe_secret.return_value = {"RotationEnabled": False, "VersionIdsToStages": self.versions}
        with self.assertRaises(RuntimeError):
            self.invoke("testSecret")
        self.connect.assert_not_called()

    def test_create_is_idempotent_and_preserves_unrelated_secrets(self):
        del self.values[TOKEN]  # Secrets Manager has staged the token but has no value yet.
        with patch.object(rotation, "_gen_password", return_value="NEW_GENERATED_PASSWORD") as generate:
            self.invoke("createSecret")
            first = dict(self.values[TOKEN])
            self.invoke("createSecret")
        generate.assert_called_once()
        self.sm.put_secret_value.assert_called_once()
        self.assertEqual(first, self.values[TOKEN])
        self.assertEqual(first, {**self.current, "password": "NEW_GENERATED_PASSWORD"})
        self.assertNotIn("host", first)

    def test_missing_pending_value_rejected_without_promotion(self):
        del self.values[TOKEN]
        for step in ("setSecret", "testSecret", "finishSecret"):
            with self.subTest(step=step), self.assertRaises(RuntimeError):
                self.invoke(step)
        self.sm.update_secret_version_stage.assert_not_called()
        self.rds.modify_db_cluster.assert_not_called()

    def test_pending_identity_mismatch_rejected(self):
        for key, value in [("username", "other-user"), ("dbname", "other-db"), ("port", 1234)]:
            with self.subTest(key=key):
                self.values[TOKEN] = {**self.pending, key: value}
                with self.assertRaises(RuntimeError):
                    self.invoke("setSecret")
        self.connect.assert_not_called()
        self.rds.modify_db_cluster.assert_not_called()

    def test_secret_user_must_be_actual_cluster_master(self):
        self.cluster["MasterUsername"] = "another-master"
        with self.assertRaises(RuntimeError):
            self.invoke("setSecret")
        self.rds.modify_db_cluster.assert_not_called()

    def test_unexpected_cluster_target_rejected(self):
        self.cluster["DBClusterArn"] = "another-cluster"
        with self.assertRaises(RuntimeError):
            self.invoke("testSecret")
        self.connect.assert_not_called()

    def test_pending_credential_authenticates_to_writer_and_selects_one(self):
        self.invoke("testSecret")
        self.rds.modify_db_cluster.assert_not_called()
        args = self.connect.call_args.kwargs
        self.assertEqual(args["host"], self.cluster["Endpoint"])
        self.assertNotIn(".proxy-", args["host"])
        self.assertEqual(args["password"], self.pending["password"])
        self.assertNotEqual(args["password"], self.current["password"])
        self.assertEqual(args["user"], "appadmin")
        self.assertEqual(args["database"], "fooddelivery")
        self.assertEqual(args["port"], 3306)
        self.assertTrue(args["ssl_verify_cert"])
        self.assertTrue(args["ssl_verify_identity"])
        self.assertTrue(Path(args["ssl_ca"]).is_file())
        for key in ("connect_timeout", "read_timeout", "write_timeout"):
            self.assertEqual(args[key], 5)
        self.cursor.execute.assert_called_once_with("SELECT 1")
        self.connection.close.assert_called_once()

    def test_set_retry_skips_already_applied_pending_password(self):
        self.invoke("setSecret")
        self.rds.modify_db_cluster.assert_not_called()

    def test_set_retains_api_update_for_only_configured_master(self):
        self.connect.side_effect = [
            rotation.pymysql.err.OperationalError(1045, "authentication rejected"),
            self.connection,
        ]
        self.invoke("setSecret")
        self.assertEqual(self.connect.call_args_list[1].kwargs["password"], "CURRENT_SECRET")
        self.rds.modify_db_cluster.assert_called_once_with(
            DBClusterIdentifier="aurora-mysql-cluster", MasterUserPassword="PENDING_SECRET",
            ApplyImmediately=True)

    def test_invalid_current_credential_never_triggers_password_reset(self):
        self.connect.side_effect = rotation.pymysql.err.OperationalError(1045, "authentication rejected")
        with self.assertRaises(RuntimeError):
            self.invoke("setSecret")
        self.rds.modify_db_cluster.assert_not_called()

    def test_set_does_not_reset_password_for_network_or_tls_failure(self):
        for code in (2003, 2026):
            self.connect.side_effect = rotation.pymysql.err.OperationalError(code, "connection rejected")
            with self.subTest(code=code), self.assertRaises(RuntimeError):
                self.invoke("setSecret")
        self.rds.modify_db_cluster.assert_not_called()

    def test_failed_pending_authentication_never_promotes(self):
        self.connect.side_effect = rotation.pymysql.err.OperationalError(1045, "failed PENDING_SECRET")
        for step in ("testSecret", "finishSecret"):
            with self.subTest(step=step), self.assertRaises(RuntimeError):
                self.invoke(step)
        self.sm.update_secret_version_stage.assert_not_called()
        self.assertEqual(self.versions[CURRENT], ["AWSCURRENT"])

    def test_failed_select_closes_connection_and_never_promotes(self):
        self.cursor.execute.side_effect = RuntimeError("failed PENDING_SECRET")
        with self.assertRaises(RuntimeError):
            self.invoke("finishSecret")
        self.connection.close.assert_called_once()
        self.sm.update_secret_version_stage.assert_not_called()

    def test_incorrect_select_result_blocks_promotion(self):
        self.cursor.fetchone.return_value = (0,)
        with self.assertRaises(RuntimeError):
            self.invoke("finishSecret")
        self.sm.update_secret_version_stage.assert_not_called()

    def test_finish_validates_before_promoting_correct_version(self):
        self.invoke("finishSecret")
        self.cursor.execute.assert_called_once_with("SELECT 1")
        self.sm.update_secret_version_stage.assert_called_once_with(
            SecretId=ARN, VersionStage="AWSCURRENT", MoveToVersionId=TOKEN, RemoveFromVersionId=CURRENT)
        self.assertEqual(self.versions[CURRENT], ["AWSPREVIOUS"])
        self.assertEqual(self.versions[TOKEN], ["AWSCURRENT"])

    def test_completed_token_is_idempotent(self):
        self.versions[TOKEN] = ["AWSCURRENT"]
        self.versions[CURRENT] = ["AWSPREVIOUS"]
        for step in rotation.STEPS:
            self.assertEqual(self.invoke(step)["status"], "ok")
        self.connect.assert_not_called()
        self.sm.update_secret_version_stage.assert_not_called()

    def test_safe_errors_and_logs_never_include_credentials_or_token(self):
        secret_text = json.dumps(self.pending)
        for failing in (self.connect, self.sm.get_secret_value, self.rds.describe_db_clusters):
            previous_effect = failing.side_effect
            failing.side_effect = RuntimeError(secret_text)
            stdout, stderr = io.StringIO(), io.StringIO()
            with self.assertLogs(rotation.logger, level=logging.INFO) as logs, \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                try:
                    self.invoke("testSecret")
                    self.fail("expected sanitized failure")
                except RuntimeError:
                    formatted = traceback.format_exc()
            output = "\n".join(logs.output) + stdout.getvalue() + stderr.getvalue() + formatted
            for secret in ("CURRENT_SECRET", "PENDING_SECRET", "PRIVATE_JWT", "PRIVATE_REFRESH", TOKEN):
                self.assertNotIn(secret, output)
            self.assertNotIn(secret_text, output)
            failing.side_effect = previous_effect
        self.sm.update_secret_version_stage.assert_not_called()

    def test_generated_password_meets_rds_constraints(self):
        for _ in range(20):
            password = rotation._gen_password()
            self.assertEqual(len(password), 20)
            self.assertFalse(any(c in password for c in '/@"\' '))
            self.assertTrue(password.isascii())

    def test_real_packaged_driver_and_ca_are_present(self):
        self.assertTrue((ROOT / "build/pymysql/__init__.py").is_file())
        self.assertTrue((ROOT / "build/pymysql-1.1.2.dist-info/METADATA").is_file())
        self.assertEqual((ROOT / "build/lambda_function.py").read_bytes(), (ROOT / "lambda_function.py").read_bytes())
        context = ssl.create_default_context(cafile=str(ROOT / "build/rds-ca-bundle.pem"))
        self.assertGreater(len(context.get_ca_certs()), 0)


if __name__ == "__main__":
    unittest.main()
