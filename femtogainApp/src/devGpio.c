/* devGpio.c
 *
 * EPICS device support for Linux GPIO character devices via libgpiod (v1 API).
 * Used by the Signal Distributor IOC to drive the GATE MUX select lines
 * (SEL0/SEL1 -> 74HCT4051) and the SEL1..4 front-panel LEDs on ODROID-C5.
 *
 * Link syntax (INST_IO):
 *     field(OUT, "@<chip> <offset> [invert]")      bo  record, DTYP "GPIO"
 *     field(INP, "@<chip> <offset> [invert]")      bi  record, DTYP "GPIO"
 *
 *     <chip>    gpiochip name, e.g. gpiochip0
 *     <offset>  line offset within the chip (see `gpioinfo`)
 *     invert    optional keyword: logical 1 drives the pin low
 *
 * A bi record pointing at a line already claimed by a bo record shares the
 * same output request and reads back the driven value; otherwise the line is
 * requested as an input.
 */

#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include <gpiod.h>

#include "alarm.h"
#include "cantProceed.h"
#include "dbDefs.h"
#include "dbAccess.h"
#include "recGbl.h"
#include "recSup.h"
#include "devSup.h"
#include "link.h"
#include "epicsMutex.h"
#include "epicsExit.h"
#include "errlog.h"
#include "iocsh.h"
#include "biRecord.h"
#include "boRecord.h"
#include "epicsExport.h"

#define CONSUMER "sigdist"
#define CHIP_NAME_MAX 32

typedef struct gpioChip {
    char name[CHIP_NAME_MAX];
    struct gpiod_chip *chip;
    struct gpioChip *next;
} gpioChip;

typedef struct gpioLine {
    gpioChip *chip;
    unsigned offset;
    struct gpiod_line *line;
    int isOutput;
    int lastValue;              /* last value driven (output lines only) */
    const char *owner;          /* record that first claimed the line */
    struct gpioLine *next;
} gpioLine;

typedef struct gpioPvt {
    gpioLine *line;
    int invert;
} gpioPvt;

static epicsMutexId gpioLock;
static gpioChip *chipList;
static gpioLine *lineList;

static void gpioAtExit(void *arg)
{
    gpioChip *c;
    (void)arg;
    for (c = chipList; c; c = c->next) {
        if (c->chip)
            gpiod_chip_close(c->chip);   /* releases all lines on the chip */
    }
}

static void gpioInitOnce(void)
{
    if (gpioLock)
        return;
    gpioLock = epicsMutexMustCreate();
    epicsAtExit(gpioAtExit, NULL);
}

static gpioChip *gpioGetChip(const char *name)
{
    gpioChip *c;
    for (c = chipList; c; c = c->next)
        if (strcmp(c->name, name) == 0)
            return c;

    c = callocMustSucceed(1, sizeof(*c), "devGpio");
    strncpy(c->name, name, sizeof(c->name) - 1);
    c->chip = gpiod_chip_open_by_name(name);
    if (!c->chip) {
        errlogPrintf("devGpio: cannot open %s: %s\n", name, strerror(errno));
        free(c);
        return NULL;
    }
    c->next = chipList;
    chipList = c;
    return c;
}

static gpioLine *gpioFindLine(gpioChip *chip, unsigned offset)
{
    gpioLine *l;
    for (l = lineList; l; l = l->next)
        if (l->chip == chip && l->offset == offset)
            return l;
    return NULL;
}

/* Claim a line. wantOutput: 1 = output, 0 = input (or share existing output). */
static gpioLine *gpioClaimLine(const char *chipName, unsigned offset,
                               int wantOutput, int initVal, const char *owner)
{
    gpioChip *chip;
    gpioLine *l;
    int rc;

    epicsMutexMustLock(gpioLock);
    chip = gpioGetChip(chipName);
    if (!chip) {
        epicsMutexUnlock(gpioLock);
        return NULL;
    }

    l = gpioFindLine(chip, offset);
    if (l) {
        /* Record types initialise in alphabetical order (bi before bo), so a
         * readback bi may have claimed the line as input first.  Upgrade it
         * to an output in place; the bi keeps sharing the same gpioLine. */
        if (wantOutput && !l->isOutput) {
            gpiod_line_release(l->line);
            rc = gpiod_line_request_output(l->line, CONSUMER, initVal);
            if (rc) {
                errlogPrintf("devGpio: re-request %s line %u as output failed: %s\n",
                             chipName, offset, strerror(errno));
                /* fall back to input so the bi still works */
                gpiod_line_request_input(l->line, CONSUMER);
                l = NULL;
            } else {
                l->isOutput = 1;
                l->lastValue = initVal;
                l->owner = owner;
            }
        }
        epicsMutexUnlock(gpioLock);
        return l;
    }

    l = callocMustSucceed(1, sizeof(*l), "devGpio");
    l->chip = chip;
    l->offset = offset;
    l->owner = owner;
    l->line = gpiod_chip_get_line(chip->chip, offset);
    if (!l->line) {
        errlogPrintf("devGpio: %s has no line %u: %s\n", chipName, offset,
                     strerror(errno));
        free(l);
        epicsMutexUnlock(gpioLock);
        return NULL;
    }

    if (wantOutput) {
        rc = gpiod_line_request_output(l->line, CONSUMER, initVal);
        l->isOutput = 1;
        l->lastValue = initVal;
    } else {
        rc = gpiod_line_request_input(l->line, CONSUMER);
    }
    if (rc) {
        errlogPrintf("devGpio: request %s line %u as %s failed: %s\n",
                     chipName, offset, wantOutput ? "output" : "input",
                     strerror(errno));
        free(l);
        epicsMutexUnlock(gpioLock);
        return NULL;
    }

    l->next = lineList;
    lineList = l;
    epicsMutexUnlock(gpioLock);
    return l;
}

/* Parse "<chip> <offset> [invert]" */
static int gpioParseLink(const char *str, char *chip, unsigned *offset,
                         int *invert)
{
    char flag[16] = "";
    int n;

    if (!str)
        return -1;
    n = sscanf(str, "%31s %u %15s", chip, offset, flag);
    if (n < 2)
        return -1;
    *invert = (n == 3 &&
               (strcmp(flag, "invert") == 0 || strcmp(flag, "inv") == 0));
    if (n == 3 && !*invert) {
        errlogPrintf("devGpio: unknown flag '%s' in link \"%s\"\n", flag, str);
        return -1;
    }
    return 0;
}

static gpioPvt *gpioInitCommon(dbCommon *prec, const struct link *plink,
                               int wantOutput)
{
    char chip[CHIP_NAME_MAX];
    unsigned offset;
    int invert;
    gpioPvt *pvt;

    gpioInitOnce();

    if (plink->type != INST_IO) {
        recGblRecordError(S_db_badField, prec,
                          "devGpio: link must be INST_IO (\"@chip offset\")");
        return NULL;
    }
    if (gpioParseLink(plink->value.instio.string, chip, &offset, &invert)) {
        recGblRecordError(S_db_badField, prec,
                          "devGpio: bad link, expected \"@<chip> <offset> [invert]\"");
        return NULL;
    }

    pvt = callocMustSucceed(1, sizeof(*pvt), "devGpio");
    pvt->invert = invert;
    /* initial physical level for outputs = logical 0 */
    pvt->line = gpioClaimLine(chip, offset, wantOutput, invert ? 1 : 0,
                              prec->name);
    if (!pvt->line) {
        recGblRecordError(S_db_badField, prec, "devGpio: cannot claim line");
        free(pvt);
        return NULL;
    }
    return pvt;
}

/* ---------------- bo ---------------- */

static long init_bo(boRecord *prec)
{
    gpioPvt *pvt = gpioInitCommon((dbCommon *)prec, &prec->out, 1);
    if (!pvt) {
        prec->pact = TRUE;   /* never process a broken record */
        return S_db_badField;
    }
    prec->dpvt = pvt;
    prec->rval = 0;      /* line was initialised to logical 0 */
    return 0;            /* convert RVAL -> VAL */
}

static long write_bo(boRecord *prec)
{
    gpioPvt *pvt = prec->dpvt;
    int logical, physical;

    if (!pvt)
        return -1;
    logical = prec->rval ? 1 : 0;
    physical = pvt->invert ? !logical : logical;

    epicsMutexMustLock(gpioLock);
    if (gpiod_line_set_value(pvt->line->line, physical)) {
        epicsMutexUnlock(gpioLock);
        recGblSetSevr(prec, WRITE_ALARM, INVALID_ALARM);
        return -1;
    }
    pvt->line->lastValue = physical;
    epicsMutexUnlock(gpioLock);
    return 0;
}

/* ---------------- bi ---------------- */

static long init_bi(biRecord *prec)
{
    gpioPvt *pvt = gpioInitCommon((dbCommon *)prec, &prec->inp, 0);
    if (!pvt) {
        prec->pact = TRUE;
        return S_db_badField;
    }
    prec->dpvt = pvt;
    return 0;
}

static long read_bi(biRecord *prec)
{
    gpioPvt *pvt = prec->dpvt;
    int physical;

    if (!pvt)
        return -1;

    epicsMutexMustLock(gpioLock);
    physical = gpiod_line_get_value(pvt->line->line);
    epicsMutexUnlock(gpioLock);

    if (physical < 0) {
        recGblSetSevr(prec, READ_ALARM, INVALID_ALARM);
        return -1;
    }
    prec->rval = pvt->invert ? !physical : physical;
    return 0;   /* convert RVAL -> VAL */
}

/* ---------------- DSETs ---------------- */

typedef struct {
    long number;
    DEVSUPFUN report;
    DEVSUPFUN init;
    DEVSUPFUN init_record;
    DEVSUPFUN get_ioint_info;
    DEVSUPFUN read_write;
} gpioDset;

gpioDset devBoGpio = { 5, NULL, NULL, (DEVSUPFUN)init_bo, NULL, (DEVSUPFUN)write_bo };
gpioDset devBiGpio = { 5, NULL, NULL, (DEVSUPFUN)init_bi, NULL, (DEVSUPFUN)read_bi };
epicsExportAddress(dset, devBoGpio);
epicsExportAddress(dset, devBiGpio);

/* ---------------- iocsh: gpioReport ---------------- */

static void gpioReport(void)
{
    gpioLine *l;
    int n = 0;

    if (!gpioLock) {
        printf("devGpio: no lines claimed\n");
        return;
    }
    printf("%-10s %6s %-6s %-5s %s\n", "chip", "line", "dir", "value", "owner");
    epicsMutexMustLock(gpioLock);
    for (l = lineList; l; l = l->next, n++) {
        int v = gpiod_line_get_value(l->line);
        printf("%-10s %6u %-6s %-5d %s\n", l->chip->name, l->offset,
               l->isOutput ? "out" : "in", v, l->owner ? l->owner : "");
    }
    epicsMutexUnlock(gpioLock);
    printf("%d line(s)\n", n);
}

static const iocshFuncDef gpioReportDef = { "gpioReport", 0, NULL,
    "List GPIO lines claimed by devGpio with direction and current value.\n" };
static void gpioReportCall(const iocshArgBuf *args) { (void)args; gpioReport(); }

static void gpioRegistrar(void)
{
    iocshRegister(&gpioReportDef, gpioReportCall);
}
epicsExportRegistrar(gpioRegistrar);
