import os
import time
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from neo4j.exceptions import AuthError, Neo4jError, ServiceUnavailable

from graph.neo import close_driver, get_driver
from graph.script import split_statements


class Command(BaseCommand):
    help = "Wait for Neo4j, then load the community movie graph if it is not loaded yet."

    def add_arguments(self, parser):
        parser.add_argument(
            "--force",
            action="store_true",
            help="Run the movie script again even if it was loaded before.",
        )
        parser.add_argument(
            "--timeout",
            type=int,
            default=180,
            help="Seconds to wait for Bolt before giving up.",
        )

    def handle(self, *args, **options):
        root = Path(os.environ["NEO4J_MOVIES_ROOT"])
        data = Path(os.environ["NEO4J_MOVIES_DATA_DIR"])
        script_path = root / "database" / "movies.cypher"
        marker = data / "movies.loaded"
        if not script_path.is_file():
            raise CommandError(f"Missing movie script: {script_path}")

        self.stdout.write(f"Waiting for Neo4j at {os.environ.get('NEO4J_URI', 'bolt://127.0.0.1:7687')}")
        self._wait(options["timeout"])

        if marker.is_file() and not options["force"]:
            self.stdout.write(self.style.SUCCESS(f"Movie graph already loaded ({marker})."))
            self._print_counts()
            return

        script = script_path.read_text(encoding="utf-8")
        statements = split_statements(script)
        if not statements:
            raise CommandError(f"No Cypher statements in {script_path}")

        self.stdout.write(f"Loading {len(statements)} statements from {script_path.name}")
        driver = get_driver()
        try:
            with driver.session() as session:
                for index, statement in enumerate(statements, start=1):
                    session.run(statement).consume()
                    if index == 1 or index % 25 == 0 or index == len(statements):
                        self.stdout.write(f"  {index}/{len(statements)}")
                        self.stdout.flush()
        except (AuthError, ServiceUnavailable, Neo4jError) as exc:
            raise CommandError(f"Movie load failed: {exc}") from exc

        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("ok\n", encoding="utf-8")
        self.stdout.write(self.style.SUCCESS("Movie graph loaded."))
        self._print_counts()

    def _wait(self, timeout: int) -> None:
        deadline = time.time() + timeout
        last = "Neo4j has not accepted a connection yet."
        while time.time() < deadline:
            try:
                close_driver()
                get_driver().verify_connectivity()
                return
            except AuthError as exc:
                raise CommandError(f"Neo4j rejected the login: {exc}") from exc
            except (ServiceUnavailable, OSError, Neo4jError) as exc:
                last = str(exc)
                close_driver()
                time.sleep(1)
        raise CommandError(f"Neo4j did not become ready: {last}")

    def _print_counts(self) -> None:
        with get_driver().session() as session:
            record = session.run(
                "RETURN count { (:Movie) } AS movies, count { (:Person) } AS people"
            ).single()
        movies = 0 if record is None else record["movies"]
        people = 0 if record is None else record["people"]
        self.stdout.write(f"Graph has {movies} movies and {people} people.")
