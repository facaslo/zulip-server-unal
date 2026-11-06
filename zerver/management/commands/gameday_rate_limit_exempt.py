from argparse import ArgumentParser
from typing import Any

from django.core.management.base import CommandError
from typing_extensions import override

from zerver.lib.management import ZulipBaseCommand

CONFIRMATION_PHRASE = "EXIMIR RATE LIMIT"


class Command(ZulipBaseCommand):
    help = """Exime o restaura el rate limiting normal (dominio api_by_user) de cuentas
bot puntuales, usando UserProfile.rate_limits. Pensado solo para las cuentas bot del
escenario de latencia del GameDay (gameday/latency_load.py); nunca dejarlo activo fuera
de la ventana del ejercicio."""

    @override
    def add_arguments(self, parser: ArgumentParser) -> None:
        self.add_realm_args(parser)
        parser.add_argument(
            "--email",
            action="append",
            dest="emails",
            required=True,
            help="Email de una cuenta bot a eximir/restaurar; repetir la flag por cada bot.",
        )
        group = parser.add_mutually_exclusive_group(required=True)
        group.add_argument(
            "--enable", action="store_true", help="Exime del rate limiting normal."
        )
        group.add_argument(
            "--disable",
            action="store_true",
            help="Restaura el rate limiting normal (borra rate_limits).",
        )
        parser.add_argument(
            "--rules",
            default="60:100000",
            help="""Reglas personalizadas 'segundos:máximo[,segundos:máximo...]' para --enable.
Por defecto un techo muy alto en vez de vacío, para mantener el código de rate
limiting ejercitado en vez de desactivarlo del todo.""",
        )
        parser.add_argument(
            "--yes-i-understand-this-weakens-rate-limiting",
            action="store_true",
            dest="skip_prompt",
            help="Omite la confirmación interactiva. Solo para los tests de este comando.",
        )

    @override
    def handle(self, *args: Any, **options: Any) -> None:
        realm = self.get_realm(options)
        users = [self.get_user(email, realm) for email in options["emails"]]

        non_bots = [user.delivery_email for user in users if not user.is_bot]
        if non_bots:
            raise CommandError(
                "Esta herramienta solo exime cuentas bot (is_bot=True); "
                f"no son bots: {', '.join(non_bots)}"
            )

        action = "eximir del" if options["enable"] else "restaurar el"
        print(f"Esto va a {action} rate limiting normal (dominio api_by_user) para:")
        for user in users:
            print(f"  - {user.delivery_email} (id={user.id})")
        print(
            "Esto NO es una simulación: modifica UserProfile.rate_limits en esta base de "
            "datos real. Usar solo con las cuentas bot de gameday/bots/, nunca de forma "
            "permanente."
        )
        if not options["skip_prompt"]:
            confirmation = input(f"Escribe «{CONFIRMATION_PHRASE}» para confirmar: ")
            if confirmation != CONFIRMATION_PHRASE:
                raise CommandError("Aborting!")

        value = options["rules"] if options["enable"] else ""
        for user in users:
            user.rate_limits = value
            user.save(update_fields=["rate_limits"])
            print(f"OK {user.delivery_email}: rate_limits={value!r}")
