import pytest
from cc_otel_sink.config import Settings

from tools._reservoir import ReservoirUnconfigured, configure_duckdb


def _settings(*, account_url=None, connection_string=None) -> Settings:
    return Settings(
        database_url="",
        blob_account_url=account_url,
        blob_connection_string=connection_string,
        blob_container="raw",
        host="127.0.0.1",
        port=8080,
    )


class _Con:
    """Capture every SQL string executed on the connection."""

    def __init__(self) -> None:
        self.sql: list[str] = []

    def execute(self, sql: str):
        self.sql.append(sql)


class _FakeToken:
    token = "HEADER.PAYLOAD.SIGNATURE"


class _FakeCredential:
    def __init__(self, *_args, **_kwargs) -> None:
        self.scopes: tuple = ()
        self.closed = False

    def get_token(self, *scopes, **_kwargs):
        self.scopes = scopes
        return _FakeToken()

    def close(self) -> None:
        self.closed = True


@pytest.fixture
def fake_credential(monkeypatch):
    created: list[_FakeCredential] = []

    def factory(*args, **kwargs):
        cred = _FakeCredential(*args, **kwargs)
        created.append(cred)
        return cred

    monkeypatch.setattr("azure.identity.DefaultAzureCredential", factory)
    return created


def test_account_url_registers_secret_with_prefetched_access_token(fake_credential):
    con = _Con()
    configure_duckdb(con, _settings(account_url="https://ccotelblob.blob.core.windows.net"))

    secret_sql = next(s for s in con.sql if "CREATE OR REPLACE SECRET" in s)
    # A prefetched OAuth token replaces PROVIDER credential_chain — DuckDB's chain
    # re-acquires a token per blob open and throttles/expires on large partitions (#99).
    assert "PROVIDER access_token" in secret_sql
    assert "ACCESS_TOKEN 'HEADER.PAYLOAD.SIGNATURE'" in secret_sql
    assert "ACCOUNT_NAME 'ccotelblob'" in secret_sql
    assert "credential_chain" not in secret_sql
    # The token is fetched against the Azure Storage OAuth scope and the credential closed.
    assert fake_credential[0].scopes == ("https://storage.azure.com/.default",)
    assert fake_credential[0].closed is True


def test_connection_string_path_is_unchanged(fake_credential):
    con = _Con()
    settings = _settings(connection_string="DefaultEndpointsProtocol=https;AccountName=x")
    configure_duckdb(con, settings)

    secret_sql = next(s for s in con.sql if "CREATE OR REPLACE SECRET" in s)
    assert "CONNECTION_STRING" in secret_sql
    assert "access_token" not in secret_sql
    assert not fake_credential  # no token fetched on the connection-string path


def test_unconfigured_raises():
    with pytest.raises(ReservoirUnconfigured):
        configure_duckdb(_Con(), _settings())
